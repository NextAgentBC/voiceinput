import Cocoa
import Carbon
import os.log

private let hotkeyLog = Logger(subsystem: "com.voiceinput.app", category: "GlobalHotkey")

/// Monitors Fn key globally using CGEvent tap with .defaultTap.
/// Requires Accessibility permission — prompts user if missing.
/// Suppresses Fn from triggering emoji picker.
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnPressed = false
    private var safetyTimer: Timer?
    private let maxHoldDuration: TimeInterval = 120
    private var retryTimer: Timer?

    func install() {
        if tryInstallTap() {
            hotkeyLog.info("Installed global Fn key monitor")
        } else {
            hotkeyLog.warning("No Accessibility permission. Requesting...")
            promptAccessibility()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if self?.tryInstallTap() == true {
                    timer.invalidate()
                    self?.retryTimer = nil
                    hotkeyLog.info("Accessibility granted — installed global Fn key monitor")
                }
            }
        }
    }

    private func tryInstallTap() -> Bool {
        if eventTap != nil { return true }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let me = Unmanaged<GlobalHotkey>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                hotkeyLog.info("Re-enabled event tap after system disabled it")
            }
            return Unmanaged.passRetained(event)
        }

        // Pre-send countdown: intercept Esc/Cmd+./Enter while auto-send is pending.
        if type == .keyDown && PreSendController.shared.isPending {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let action = PreSendController.shared.handleKeyDown(keyCode: keyCode, flags: event.flags)
            if action == .consume { return nil }
        }

        // Any non-synthetic input event during the "paste → send" window
        // means the user is editing. Cancel LLM overwrite + auto-send,
        // preserve the pasted text, and we'll learn from their final version
        // when they eventually press Enter.
        let rec = RecordingSession.shared
        let pre = PreSendController.shared
        let inEditWindow = (rec.isRefining || pre.isPending)
            && !rec.isInjecting
            && !pre.isFiringOwnEnter

        if type == .keyDown && inEditWindow {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let isEsc = keyCode == 53
            let isCmdDot = keyCode == 47 && event.flags.contains(.maskCommand)
            if isEsc || isCmdDot {
                DispatchQueue.main.async {
                    rec.cancelRecording()
                }
                return nil
            }
            // Any other keyDown (arrow, backspace, printable, Enter) →
            // treat as user editing intent. We do NOT consume the event,
            // so their typing lands normally in the app.
            DispatchQueue.main.async {
                rec.userStartedEditing()
            }
        }

        if (type == .leftMouseDown || type == .rightMouseDown) && inEditWindow {
            DispatchQueue.main.async {
                rec.userStartedEditing()
            }
        }

        // User pressed Enter on a pasted utterance (auto-send not pending
        // and not our own synthetic Enter). Read AX *synchronously* here —
        // before Enter reaches the app and clears the input box.
        if type == .keyDown
            && !pre.isPending
            && !pre.isFiringOwnEnter
            && !rec.isInjecting {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 0x24 {
                let captured = FocusedTextReader.read()
                DispatchQueue.main.async {
                    rec.learnFromUserEditIfAny(capturedText: captured)
                }
                // Let Enter pass through to the app.
            }
        }

        // Fn press/release ONLY comes from flagsChanged events on keyCode 63.
        // Arrow keys (123-126) emit keyDown with .maskSecondaryFn set too,
        // so we must not read the flag on non-flagsChanged events.
        if type == .flagsChanged {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == 63 else { return Unmanaged.passRetained(event) }

            let fnDown = event.flags.contains(.maskSecondaryFn)

            if fnDown && !fnPressed {
                fnPressed = true
                DispatchQueue.main.async { [weak self] in
                    self?.onHotkeyDown?()
                    self?.startSafetyTimer()
                }
                return nil
            } else if !fnDown && fnPressed {
                fnPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.stopSafetyTimer()
                    self?.onHotkeyUp?()
                }
                return nil
            }
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Safety Timer

    private func startSafetyTimer() {
        stopSafetyTimer()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: maxHoldDuration, repeats: false) { [weak self] _ in
            guard let self = self, self.fnPressed else { return }
            hotkeyLog.warning("Safety timer fired after \(self.maxHoldDuration)s — auto-releasing")
            self.fnPressed = false
            self.onHotkeyUp?()
        }
    }

    private func stopSafetyTimer() {
        safetyTimer?.invalidate()
        safetyTimer = nil
    }
}
