import Foundation
import Speech
import AVFoundation

final class SpeechRecognizer {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onError: ((Error) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var lastPartialResult: String = ""

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    func startRecording(locale: String) throws {
        // Cancel any ongoing task
        _ = stopRecording()

        let speechLocale = Locale(identifier: locale)
        recognizer = SFSpeechRecognizer(locale: speechLocale)

        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // Use server-side recognition for better mixed-language support;
        // falls back to on-device automatically when offline
        request.requiresOnDeviceRecognition = false

        // Load custom vocabulary to help recognize English terms in Chinese mode
        let customVocab = Self.loadCustomVocabulary()
        if !customVocab.isEmpty {
            request.contextualStrings = customVocab
        }

        self.recognitionRequest = request
        self.lastPartialResult = ""

        // Start recognition task
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.onFinalResult?(text)
                    }
                } else {
                    self.lastPartialResult = text
                    DispatchQueue.main.async {
                        self.onPartialResult?(text)
                    }
                }
            }

            if let error = error {
                // Ignore cancellation errors
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                    // Recognition cancelled, not a real error
                    return
                }
                DispatchQueue.main.async {
                    self.onError?(error)
                }
            }
        }

        // Configure audio engine
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Feed buffer to speech recognizer
            self.recognitionRequest?.append(buffer)

            // Calculate RMS for waveform visualization
            let rms = self.calculateRMS(buffer: buffer)
            DispatchQueue.main.async {
                self.onAudioLevel?(rms)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopRecording() -> String {
        let finalText = lastPartialResult

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        recognizer = nil

        return finalText
    }

    // MARK: - Custom Vocabulary

    /// Load vocabulary from ~/.voiceinput/vocabulary.txt (one word/phrase per line)
    /// Falls back to a built-in set of common tech terms
    private static func loadCustomVocabulary() -> [String] {
        let vocabURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voiceinput/vocabulary.txt")

        if FileManager.default.fileExists(atPath: vocabURL.path),
           let content = try? String(contentsOf: vocabURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            if !lines.isEmpty { return lines }
        }

        // Create default vocabulary file
        let defaults = Self.defaultVocabulary
        let content = "# VoiceInput Custom Vocabulary\n"
            + "# One word or phrase per line. Helps recognize English terms in Chinese mode.\n"
            + "# Edit and reload from the menu bar.\n\n"
            + defaults.joined(separator: "\n") + "\n"
        try? content.write(to: vocabURL, atomically: true, encoding: .utf8)

        return defaults
    }

    private static let defaultVocabulary = [
        // Programming
        "Python", "JavaScript", "TypeScript", "Swift", "Java", "Kotlin", "Rust", "Go",
        "React", "Vue", "Angular", "Node.js", "Next.js", "Django", "Flask", "FastAPI",
        "Docker", "Kubernetes", "GitHub", "GitLab", "API", "REST", "GraphQL", "SQL",
        "JSON", "YAML", "HTML", "CSS", "HTTP", "HTTPS", "URL", "SSH", "CLI",
        "Claude", "OpenAI", "GPT", "LLM", "AI", "ML",
        // Common English
        "OK", "email", "app", "server", "database", "deploy", "debug", "login", "logout",
        "push", "pull", "merge", "commit", "branch", "release", "update", "download",
        "upload", "config", "setup", "install", "build", "test", "run",
        // Names / brands
        "Google", "Apple", "Microsoft", "Amazon", "Slack", "Discord", "Telegram",
        "WeChat", "macOS", "iOS", "Android", "Linux", "Windows", "Chrome", "Safari",
    ]

    private func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }

        let channelDataValue = channelData.pointee
        let frameLength = Int(buffer.frameLength)

        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelDataValue[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))

        // Convert to a 0-1 range with some amplification
        // Typical speech RMS is 0.01-0.1, so we scale up
        let normalized = min(rms * 5.0, 1.0)
        return normalized
    }
}

enum SpeechError: LocalizedError {
    case recognizerUnavailable
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer is not available for the selected language."
        case .notAuthorized:
            return "Speech recognition is not authorized."
        }
    }
}
