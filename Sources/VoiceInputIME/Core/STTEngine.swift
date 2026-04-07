import Foundation

/// Common interface for all speech-to-text engines.
protocol STTEngine: AnyObject {
    var onAudioLevel: ((Float) -> Void)? { get set }
    func startRecording(language: String) throws
    func stopRecording(context: String) async -> String
}

enum STTEngineType: String, CaseIterable {
    case apple = "apple"
    case cloud = "cloud"
    case whisper = "whisper"

    var displayName: String {
        switch self {
        case .apple: return "Apple (Local)"
        case .cloud: return "Cloud API"
        case .whisper: return "Local Whisper"
        }
    }

    var description: String {
        switch self {
        case .apple: return "Free, offline, no setup needed"
        case .cloud: return "Custom STT server (requires API key)"
        case .whisper: return "Local Whisper model (coming soon)"
        }
    }
}
