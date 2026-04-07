import Foundation
import Speech
import AVFoundation

/// Local STT engine using Apple's Speech.framework. Free, offline, no API key needed.
final class AppleSpeechEngine: STTEngine {
    var onAudioLevel: ((Float) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var finalText = ""
    private var isRecording = false

    func startRecording(language: String) throws {
        guard !isRecording else { return }

        let locale = Locale(identifier: language)
        speechRecognizer = SFSpeechRecognizer(locale: locale)

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw STTError.noInputDevice
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 15, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request
        finalText = ""

        // Start recognition task
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                self.finalText = result.bestTranscription.formattedString
            }
            if error != nil || (result?.isFinal ?? false) {
                // Recognition ended
            }
        }

        // Install audio tap
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw STTError.noInputDevice }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            self.recognitionRequest?.append(buffer)
            let level = self.rms(buffer)
            DispatchQueue.main.async { self.onAudioLevel?(level) }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stopRecording(context: String) async -> String {
        guard isRecording else { return "" }
        isRecording = false

        recognitionRequest?.endAudio()

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil

        // Wait briefly for final result
        try? await Task.sleep(nanoseconds: 500_000_000)

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let result = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[AppleSpeech] \"%@\"", result)
        return result
    }

    // MARK: - Permission

    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    // MARK: - Audio Level

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        let p = data.pointee
        for i in 0..<n { sum += p[i] * p[i] }
        return min(sqrt(sum / Float(n)) * 5.0, 1.0)
    }
}
