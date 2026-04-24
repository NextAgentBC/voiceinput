import Foundation
import os.log

private let whisperLog = Logger(subsystem: "com.voiceinput.app", category: "Whisper")

/// Local Whisper STT engine (placeholder — not yet implemented).
final class WhisperEngine: STTEngine {
    var onAudioLevel: ((Float) -> Void)?

    func startRecording(language: String) throws {
        whisperLog.error("Local Whisper engine is not yet available")
        throw STTError.noInputDevice
    }

    func stopRecording(context: String) async -> String {
        return ""
    }
}
