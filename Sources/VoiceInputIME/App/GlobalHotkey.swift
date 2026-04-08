import Cocoa
import Carbon

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

    /// Install the global event tap. Retries automatically if permission not yet granted.
    func install() {
        if tryInstallTap() {
            NSLog("[GlobalHotkey] Installed global Fn key monitor")
        } else {
            NSLog("[GlobalHotkey] No Accessibility permission. Requesting...")
            promptAccessibility()
            // Retry every 2 seconds until permission is granted
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if self?.tryInstallTap() == true {
                    timer.invalidate()
                    self?.retryTimer = nil
                    NSLog("[GlobalHotkey] Accessibility granted — installed global Fn key monitor")
                }
            }
        }
    }

    private func tryInstallTap() -> Bool {
        // Check if we already have a tap
        if eventTap != nil { return true }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // Can suppress Fn key
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

    /// Prompt the user to enable Accessibility permission
    private func promptAccessibility() {
        // This triggers the system "allow Accessibility" dialog
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private var zHandled = false
    private var wasToggle = false

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Auto-re-enable if macOS disabled the tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                NSLog("[GlobalHotkey] Re-enabled event tap after system disabled it")
            }
            return Unmanaged.passRetained(event)
        }

        // Fn+Z → toggle meeting session (Z keycode = 0x06)
        if type == .keyDown && fnPressed {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 0x06 && !zHandled {
                zHandled = true
                wasToggle = true
                DispatchQueue.main.async {
                    // Cancel push-to-talk recording that started with Fn
                    RecordingSession.shared.cancelRecording()
                    // Toggle continuous meeting session
                    MeetingModeDetector.shared.toggle()
                }
                return nil
            }
            // Suppress Z repeats
            if keyCode == 0x06 { return nil }
        }

        let flags = event.flags
        let fnDown = flags.contains(.maskSecondaryFn)

        if fnDown && !fnPressed {
            // Fn pressed — start push-to-talk (unless meeting session will cancel it)
            fnPressed = true
            zHandled = false
            wasToggle = false
            // Don't start recording if meeting session is running (Fn is for toggle only)
            if !MeetingSession.shared.isRunning {
                DispatchQueue.main.async { [weak self] in
                    self?.onHotkeyDown?()
                    self?.startSafetyTimer()
                }
            }
            return nil
        } else if !fnDown && fnPressed {
            // Fn released
            fnPressed = false
            zHandled = false
            if !wasToggle && !MeetingSession.shared.isRunning {
                DispatchQueue.main.async { [weak self] in
                    self?.stopSafetyTimer()
                    self?.onHotkeyUp?()
                }
            }
            wasToggle = false
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Safety Timer (auto-stop stuck holds)

    private func startSafetyTimer() {
        stopSafetyTimer()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: maxHoldDuration, repeats: false) { [weak self] _ in
            guard let self = self, self.fnPressed else { return }
            NSLog("[GlobalHotkey] Safety timer fired after %.0fs — auto-releasing", self.maxHoldDuration)
            self.fnPressed = false
            self.onHotkeyUp?()
        }
    }

    private func stopSafetyTimer() {
        safetyTimer?.invalidate()
        safetyTimer = nil
    }
}
