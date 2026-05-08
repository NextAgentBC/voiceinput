import Foundation

/// Common interface for all speech-to-text engines.
protocol STTEngine: AnyObject {
    var onAudioLevel: ((Float) -> Void)? { get set }
    /// Live partial transcription. Engines that don't support streaming may
    /// never call this. Always invoked on the main queue.
    var onPartialTranscript: ((String) -> Void)? { get set }
    func startRecording(language: String) throws
    func stopRecording(context: String) async -> Result<String, STTError>
}

enum SendKeyType: String, CaseIterable, Codable {
    case enter = "enter"
    case cmdEnter = "cmdEnter"

    var displayName: String {
        switch self {
        case .enter: return "Enter"
        case .cmdEnter: return "Cmd+Enter"
        }
    }
}

enum STTError: LocalizedError, Equatable {
    case noInputDevice
    case noPermission
    case notConfigured
    case network(String)
    case http(Int)
    case parseFailure
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice:     return "No audio input device available."
        case .noPermission:      return "Microphone or speech recognition permission denied."
        case .notConfigured:     return "STT endpoint or API key is not configured."
        case .network(let r):    return "Network error: \(r)"
        case .http(let c):       return "STT server returned HTTP \(c)."
        case .parseFailure:      return "Failed to parse STT server response."
        case .engineUnavailable: return "Speech recognition engine unavailable."
        }
    }

    /// Short user-facing string for toasts (≤ 32 chars).
    var userMessage: String {
        switch self {
        case .noInputDevice:     return "Microphone unavailable"
        case .noPermission:      return "Microphone permission denied"
        case .notConfigured:     return "Whisper not configured"
        case .network:           return "Network error"
        case .http(let c):       return "STT server: HTTP \(c)"
        case .parseFailure:      return "STT response parse failed"
        case .engineUnavailable: return "Speech engine unavailable"
        }
    }
}

enum STTEngineType: String, CaseIterable, Codable {
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
