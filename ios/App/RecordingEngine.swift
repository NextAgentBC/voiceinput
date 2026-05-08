import Foundation
import Speech
import AVFoundation
import os.log

private let engineLog = Logger(subsystem: "com.voiceinput.app", category: "RecordingEngine")

final class RecordingEngine: @unchecked Sendable {

    static let shared = RecordingEngine()

    // MARK: - Public state (main-thread reads expected from SwiftUI)

    private(set) var isRecording = false

    // MARK: - Private state

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    private var currentRequestID: UUID?
    private var latestText = ""
    private var lastPartialPostTime: Date = .distantPast
    private var lastAudioLevel: Float = 0

    // Continuation race guard.
    // NSLock makes the mutable fields below safe to access from the recognition
    // callback thread AND from the actor task-group children.
    private let continuationLock = NSLock()
    private var finalContinuation: CheckedContinuation<String, Never>?
    private var finalEmitted = false

    private init() {}

    // MARK: - Public API

    /// Start a new recording session for `requestID`. Returns when recording completes
    /// (final result emitted, error, or cancel). Call on main thread or in a Task.
    func start(requestID: UUID, language: String) async {
        guard !isRecording else {
            engineLog.warning("start called while already recording — ignoring")
            return
        }

        currentRequestID = requestID
        latestText = ""
        lastAudioLevel = 0
        lastPartialPostTime = .distantPast

        continuationLock.lock()
        finalEmitted = false
        finalContinuation = nil
        continuationLock.unlock()

        AppGroupBridge.writeStatus(AppGroupBridge.LiveStatus(
            requestID: requestID,
            phase: .starting,
            partialText: nil,
            audioLevel: 0
        ))
        AppGroupBridge.post(AppGroupBridge.didUpdateStatusNotification)

        do {
            try await startRecognition(requestID: requestID, language: language)
        } catch {
            engineLog.error("RecordingEngine error: \(error.localizedDescription, privacy: .public)")
            AppGroupBridge.writeStatus(AppGroupBridge.LiveStatus(
                requestID: requestID,
                phase: .error,
                audioLevel: 0,
                errorMessage: error.localizedDescription
            ))
            AppGroupBridge.post(AppGroupBridge.didFinishResultNotification)
            cleanup()
        }
    }

    /// Signal end of audio. The recognition task will produce a final result.
    func stop() {
        guard isRecording else { return }
        recognitionRequest?.endAudio()
    }

    /// Abort without producing a Result.
    func cancel() {
        guard let id = currentRequestID else { return }
        recognitionTask?.cancel()
        AppGroupBridge.writeStatus(AppGroupBridge.LiveStatus(
            requestID: id,
            phase: .cancelled,
            audioLevel: 0
        ))
        AppGroupBridge.post(AppGroupBridge.didFinishResultNotification)

        continuationLock.lock()
        if !finalEmitted, let cont = finalContinuation {
            finalEmitted = true
            finalContinuation = nil
            continuationLock.unlock()
            cont.resume(returning: latestText)
        } else {
            continuationLock.unlock()
        }
        cleanup()
    }

    // MARK: - Core recognition

    private func startRecognition(requestID: UUID, language: String) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let locale = Locale(identifier: language)
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw RecordingError.recognizerUnavailable
        }
        speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            request.append(buffer)
            let level = Self.rmsLevel(buffer: buffer)
            let scaled = min(level * 5.0, 1.0)
            self.lastAudioLevel = scaled
        }

        engine.prepare()
        try engine.start()
        isRecording = true

        AppGroupBridge.writeStatus(AppGroupBridge.LiveStatus(
            requestID: requestID,
            phase: .recording,
            partialText: nil,
            audioLevel: 0
        ))
        AppGroupBridge.post(AppGroupBridge.didUpdateStatusNotification)

        // Recognition task: fires on an internal recognizer queue (not main thread).
        // Accesses to finalEmitted / finalContinuation are guarded by continuationLock.
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                self.latestText = text
                self.emitPartial(requestID: requestID, text: text)
            }

            if result?.isFinal == true || error != nil {
                self.continuationLock.lock()
                guard !self.finalEmitted, let cont = self.finalContinuation else {
                    self.continuationLock.unlock()
                    return
                }
                self.finalEmitted = true
                self.finalContinuation = nil
                let text = self.latestText
                self.continuationLock.unlock()
                cont.resume(returning: text)
            }
        }

        // Race: isFinal callback vs 1.5 s deadline — mirror macOS AppleSpeechEngine.
        let finalText: String = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { cont in
                    self.continuationLock.lock()
                    if self.finalEmitted {
                        let text = self.latestText
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
                self.continuationLock.lock()
                guard !self.finalEmitted, let cont = self.finalContinuation else {
                    self.continuationLock.unlock()
                    return nil
                }
                self.finalEmitted = true
                self.finalContinuation = nil
                let text = self.latestText
                self.continuationLock.unlock()
                cont.resume(returning: text)
                return nil
            }
            var result: String?
            for await value in group {
                if let v = value {
                    result = v
                    group.cancelAll()
                    break
                }
            }
            return result ?? latestText
        }

        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        engineLog.info("final: \(trimmed, privacy: .private)")

        let bridgeResult = AppGroupBridge.Result(
            requestID: requestID,
            text: trimmed,
            timestamp: Date()
        )
        AppGroupBridge.writeResult(bridgeResult)
        AppGroupBridge.writeStatus(AppGroupBridge.LiveStatus(
            requestID: requestID,
            phase: .done,
            partialText: trimmed,
            audioLevel: 0
        ))
        AppGroupBridge.post(AppGroupBridge.didFinishResultNotification)
        cleanup()
    }

    // MARK: - Helpers

    private func emitPartial(requestID: UUID, text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastPartialPostTime) >= 0.15 else { return }
        lastPartialPostTime = now
        AppGroupBridge.writeStatus(AppGroupBridge.LiveStatus(
            requestID: requestID,
            phase: .recording,
            partialText: text,
            audioLevel: lastAudioLevel
        ))
        AppGroupBridge.post(AppGroupBridge.didUpdateStatusNotification)
    }

    private func cleanup() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, channelCount > 0 else { return 0 }
        var sum: Float = 0
        for ch in 0..<channelCount {
            let data = channelData[ch]
            for i in 0..<frameCount {
                let s = data[i]
                sum += s * s
            }
        }
        let mean = sum / Float(frameCount * channelCount)
        return mean > 0 ? sqrt(mean) : 0
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer unavailable for the selected language."
        }
    }
}
