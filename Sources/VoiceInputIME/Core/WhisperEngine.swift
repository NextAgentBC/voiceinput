import Foundation

/// Local Whisper STT engine (placeholder — will be implemented in v0.2).
final class WhisperEngine: STTEngine {
    var onAudioLevel: ((Float) -> Void)?

    func startRecording(language: String) throws {
        NSLog("[Whisper] Local Whisper engine is not yet available")
        throw STTError.noInputDevice
    }

    func stopRecording(context: String) async -> String {
        return ""
    }
}
