import Cocoa
import Carbon
import os.log

private let preSendLog = Logger(subsystem: "com.voiceinput.app", category: "PreSend")

/// Manages the post-paste / pre-send window:
///   1. Text is pasted into target app immediately.
///   2. PreSendController starts a countdown to auto-send.
///   3. During countdown, certain keys short-circuit:
///        - Esc / Cmd+.  → cancel send, text stays in input box
///        - Enter        → send immediately (skip delay)
///        - Any other printable key → cancel send silently, user is editing
final class PreSendController {
    static let shared = PreSendController()

    private var timer: Timer?
    private var pendingSendKey: SendKeyType = .enter

    private init() {}

    var isPending: Bool { timer != nil }

    /// Schedule auto-send after `delay` seconds. Cancels any prior pending send.
    func schedule(delay: TimeInterval, sendKey: SendKeyType) {
        cancel()
        pendingSendKey = sendKey
        preSendLog.info("schedule: delay=\(delay)s, key=\(sendKey.rawValue, privacy: .public)")
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.fireSend()
        }
    }

    /// Fire the send immediately (user pressed Enter during countdown).
    func sendNow() {
        guard isPending else { return }
        preSendLog.info("sendNow")
        cancelTimerOnly()
        fireSend()
    }

    /// Cancel the pending send. Text remains pasted.
    /// `userInitiated = true` means Esc/Cmd+./etc. — a signal the refined
    /// text may be wrong. `false` is used when another subsystem aborts
    /// (e.g. new recording starts) and should not be treated as feedback.
    func cancel(userInitiated: Bool = false) {
        guard isPending else { return }
        preSendLog.info("cancel (user=\(userInitiated, privacy: .public))")
        cancelTimerOnly()
        if userInitiated {
            RecordingSession.shared.reportUserCancelledSend()
        }
    }

    private func cancelTimerOnly() {
        timer?.invalidate()
        timer = nil
    }

    /// True while we are posting our own synthetic Enter. The GlobalHotkey
    /// tap uses this to avoid treating our Enter as a "user pressed Enter"
    /// signal (which would trigger redundant learning).
    private(set) var isFiringOwnEnter = false

    private func fireSend() {
        // Set the "we are firing" flag FIRST, before invalidating the timer,
        // so any observer that sees `!isPending` also sees `isFiringOwnEnter`.
        isFiringOwnEnter = true
        timer = nil

        // Learn from any user edits to the pasted text before sending.
        RecordingSession.shared.learnFromUserEditIfAny()

        let src = CGEventSource(stateID: .combinedSessionState)
        let useCmd = pendingSendKey == .cmdEnter
        if let d = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true) {
            if useCmd { d.flags = .maskCommand }
            d.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let u = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false) {
            if useCmd { u.flags = .maskCommand }
            u.post(tap: .cgAnnotatedSessionEventTap)
        }

        // The accepted-send bookkeeping also clears lastPastedText, so even
        // if our Enter bounces through the tap, there's nothing to diff.
        RecordingSession.shared.reportAcceptedSend()

        // Keep the isFiring flag up long enough to cover the round-trip of
        // our synthetic Enter through the event tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.isFiringOwnEnter = false
        }
    }

    // MARK: - Key Interception (called from GlobalHotkey tap)

    enum KeyAction {
        case passthrough
        case consume
    }

    /// Decide how to handle a keyDown while a send is pending.
    /// Returns `.consume` to suppress the event from reaching the foreground app.
    func handleKeyDown(keyCode: Int64, flags: CGEventFlags) -> KeyAction {
        guard isPending else { return .passthrough }

        // Esc — cancel, consume (chat app should not clear draft)
        if keyCode == 53 {
            cancel(userInitiated: true)
            return .consume
        }

        // Cmd+. (period = keycode 47)
        if keyCode == 47 && flags.contains(.maskCommand) {
            cancel(userInitiated: true)
            return .consume
        }

        // Enter — send now, consume (we will post our own send; avoid double)
        if keyCode == 0x24 {
            sendNow()
            return .consume
        }

        // Everything else: user is editing the pasted text — cancel auto-send,
        // let key through. Treat as weak rejection (they did not wait for send).
        cancel(userInitiated: true)
        return .passthrough
    }
}
