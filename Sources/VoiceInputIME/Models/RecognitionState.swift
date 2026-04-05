import Foundation

enum InputMode {
    case hold        // Hold Fn to record, release to send
    case continuous  // Tap Fn to start, silence auto-sends, tap Fn to stop
}

enum RecognitionState {
    case idle
    case recording(partialText: String, mode: InputMode)
    case refining(text: String)
    case injecting(text: String)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isRefining: Bool {
        if case .refining = self { return true }
        return false
    }

    var recordingMode: InputMode? {
        if case .recording(_, let mode) = self { return mode }
        return nil
    }

    var displayText: String {
        switch self {
        case .idle:
            return ""
        case .recording(let text, _):
            return text
        case .refining:
            return "Refining..."
        case .injecting(let text):
            return text
        }
    }
}
