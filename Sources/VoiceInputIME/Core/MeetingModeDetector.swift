import Cocoa

extension Notification.Name {
    static let meetingModeDidChange = Notification.Name("MeetingModeDidChange")
}

/// Meeting mode toggle via Fn+Z global hotkey.
final class MeetingModeDetector {
    static let shared = MeetingModeDetector()

    private(set) var isActive: Bool = false

    private init() {}

    func toggle() {
        isActive.toggle()
        NSLog("[MeetingMode] %@", isActive ? "ACTIVE" : "INACTIVE")

        if isActive {
            MeetingSession.shared.start()
        } else {
            MeetingSession.shared.stop()
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .meetingModeDidChange, object: nil)
        }
    }
}
