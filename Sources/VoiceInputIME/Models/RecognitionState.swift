import Foundation

enum RecognitionState {
    case idle
    case recording
    case refining

    var isIdle: Bool { if case .idle = self { return true }; return false }
    var isRecording: Bool { if case .recording = self { return true }; return false }
    var isRefining: Bool { if case .refining = self { return true }; return false }
}
