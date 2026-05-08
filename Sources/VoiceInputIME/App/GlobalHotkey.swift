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

        let rec = RecordingSession.shared
        let pre = PreSendController.shared

        // Cmd+C while the floating panel has a visible transcript: copy our
        // partial / final text to the pasteboard instead of the foreground
        // app's selection. The user is offered this via a "⌘C to copy" hint.
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let isCmdC = keyCode == 8
                && flags.contains(.maskCommand)
                && !flags.contains(.maskShift)
                && !flags.contains(.maskAlternate)
                && !flags.contains(.maskControl)
            if isCmdC, rec.copyableTranscriptNonisolated != nil {
                DispatchQueue.main.async { rec.copyVisibleTranscript() }
                return nil  // consume so the foreground app doesn't also copy.
            }
        }

        // Any non-synthetic input event during the "paste → send" window
        // means the user is editing. Cancel LLM overwrite + auto-send,
        // preserve the pasted text, and we'll learn from their final version
        // when they eventually press Enter.
        // Use nonisolated atomic readers — this callback runs off the main thread.
        let inEditWindow = (rec.isRefiningNonisolated || pre.isPending)
            && !rec.isInjectingNonisolated
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
            && !rec.isInjectingNonisolated {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 0x24 {
                let captured = FocusedTextReader.read()
                DispatchQueue.main.async {
                    rec.learnFromUserEditIfAny(capturedText: captured)
                }
                // Let Enter pass through to the app.
            }
        }

        // Hotkey: Fn+Ctrl held together. Using a combo (rather than Fn alone)
        // avoids accidental triggers when the user taps Fn during normal
        // typing or via the globe-key shortcut. Both keys must be held; a
        // release of EITHER ends the recording. Fn key = keyCode 63,
        // Control = 59 (left) / 62 (right). flagsChanged fires once per
        // modifier transition, so we read the combined flag state from the
        // event itself rather than tracking each key separately.
        // Arrow keys (123-126) emit keyDown with .maskSecondaryFn set too,
        // so we must not read these flags on non-flagsChanged events.
        if type == .flagsChanged {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // Only consider transitions for the keys involved in our combo.
            guard keyCode == 63 || keyCode == 59 || keyCode == 62 else {
                return Unmanaged.passRetained(event)
            }

            // Strict: ONLY Fn+Ctrl. Any extra modifier (Option, Shift, Cmd)
            // means the user is doing some other shortcut — don't toggle
            // recording. Loose match (just `contains(.maskSecondaryFn) &&
            // contains(.maskControl)`) caused false triggers when Option
            // got added on top of Fn+Ctrl.
            let bothDown = event.flags.contains(.maskSecondaryFn)
                        && event.flags.contains(.maskControl)
                        && !event.flags.contains(.maskAlternate)
                        && !event.flags.contains(.maskShift)
                        && !event.flags.contains(.maskCommand)

            if bothDown && !fnPressed {
                fnPressed = true
                DispatchQueue.main.async { [weak self] in
                    self?.onHotkeyDown?()
                    self?.startSafetyTimer()
                }
                return nil
            } else if !bothDown && fnPressed {
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
