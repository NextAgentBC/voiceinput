import Foundation
import Speech
import AVFoundation
import os.log

private let appleLog = Logger(subsystem: "com.voiceinput.app", category: "AppleSpeech")

/// Local STT engine using Apple's Speech.framework. Free, offline, no API key needed.
final class AppleSpeechEngine: STTEngine {
    var onAudioLevel: ((Float) -> Void)?
    var onPartialTranscript: ((String) -> Void)?

    private var capture = AudioCaptureSession()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var finalText = ""
    private var isRecording = false

    // Continuation + guard for the isFinal-based stop path (B1).
    // Protected by continuationLock — never resume without holding the lock.
    private let continuationLock = NSLock()
    private var finalContinuation: CheckedContinuation<String, Never>?
    private var finalEmitted = false

    func startRecording(language: String) throws {
        guard !isRecording else { return }

        // Clear any leftover continuation from a previous (possibly cancelled) run.
        continuationLock.lock()
        if let stale = finalContinuation {
            finalContinuation = nil
            continuationLock.unlock()
            stale.resume(returning: finalText)
        } else {
            continuationLock.unlock()
        }
        continuationLock.lock()
        finalEmitted = false
        finalContinuation = nil
        continuationLock.unlock()

        let locale = Locale(identifier: language)
        speechRecognizer = SFSpeechRecognizer(locale: locale)

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw STTError.noInputDevice
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 15, *) {
            request.addsPunctuation = true
        }
        // Feed the user's personal vocabulary (custom names, tech terms,
        // project names) as priors so Apple Speech can recognise them.
        let priorTerms = VocabularyDB.shared.topCorrectedTerms(limit: 100)
        if !priorTerms.isEmpty {
            request.contextualStrings = priorTerms
            appleLog.info("contextualStrings: \(priorTerms.count) terms")
        }
        recognitionRequest = request
        finalText = ""

        // Start recognition task
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.finalText = text
                DispatchQueue.main.async { self.onPartialTranscript?(text) }
            }
            // Resume the continuation exactly once when Apple declares the
            // result final (or when an error terminates recognition).
            if result?.isFinal == true || error != nil {
                self.continuationLock.lock()
                guard !self.finalEmitted, let cont = self.finalContinuation else {
                    self.continuationLock.unlock()
                    return
                }
                self.finalEmitted = true
                self.finalContinuation = nil
                let text = self.finalText
                self.continuationLock.unlock()
                cont.resume(returning: text)
            }
        }

        let cfg = AudioCaptureSession.Config(
            onBuffer: { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            },
            onLevel: { [weak self] level in
                self?.onAudioLevel?(level)
            },
            bufferSize: 1024
        )
        try capture.start(config: cfg)
        isRecording = true
    }

    func stopRecording(context: String) async -> Result<String, STTError> {
        guard isRecording else { return .success("") }
        isRecording = false

        recognitionRequest?.endAudio()
        capture.stop()

        // Race: wait for the recognizer's isFinal callback vs. a 1.5 s deadline.
        // The continuation is set here and resumed either by the recognition
        // callback above or by the deadline branch below — exactly once.
        let recognized: String = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { cont in
                    self.continuationLock.lock()
                    if self.finalEmitted {
                        // Already fired before we even got here.
                        let text = self.finalText
                        self.continuationLock.unlock()
                        cont.resume(returning: text)
                    } else {
                        self.finalContinuation = cont
                        self.continuationLock.unlock()
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // Deadline: manually resume the continuation if isFinal hasn't
                // fired yet so child A doesn't hang indefinitely.
                self.continuationLock.lock()
                guard !self.finalEmitted, let cont = self.finalContinuation else {
                    self.continuationLock.unlock()
                    return nil
                }
                self.finalEmitted = true
                self.finalContinuation = nil
                let text = self.finalText
                self.continuationLock.unlock()
                cont.resume(returning: text)
                return nil
            }
            // Take whichever child returns a non-nil value first (child A),
            // or fall back to finalText if only the deadline branch fired.
            var result: String? = nil
            for await value in group {
                if let v = value {
                    result = v
                    group.cancelAll()
                    break
                }
            }
            return result ?? finalText
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let result = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        appleLog.info("result: \(result, privacy: .private)")
        return .success(result)
    }

    // MARK: - Permission

    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }
}
