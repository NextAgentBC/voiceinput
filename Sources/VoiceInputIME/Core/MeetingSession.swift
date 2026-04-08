import Cocoa
import AVFoundation

/// Continuous meeting recording session.
///
/// Strategy: record continuously, every ~60s at a natural pause send the chunk
/// to the server for background processing. Results accumulate in order.
/// On stop: wait for all results, paste everything at once + summary.
final class MeetingSession {
    static let shared = MeetingSession()

    private var _isRunning = false
    private let stateLock = NSLock()
    private(set) var isRunning: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isRunning }
        set { stateLock.lock(); _isRunning = newValue; stateLock.unlock() }
    }
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pcmData = Data()
    private let pcmLock = NSLock()
    private var tapInstalled = false

    // Segmentation config
    private let minSegmentSeconds: TimeInterval = 8      // don't flush before 8s
    private let maxSegmentDuration: TimeInterval = 15    // force flush at 15s
    private let silenceThreshold: Float = 0.01
    private let silenceDuration: TimeInterval = 0.8      // pause detection

    // VAD state
    private var isSpeaking = false
    private var silenceStart: Date?
    private var segmentStart: Date?
    private var vadTimer: Timer?

    // Ordered results
    private var segmentCounter = 0
    private var results: [Int: String] = [:]
    private var accumulatedTranscript = ""
    private var pendingCount = 0
    private let resultsLock = NSLock()

    // Timestamp tracking
    private var sessionStart: Date?

    var onStatusChange: ((Bool) -> Void)?

    private init() {}

    // MARK: - Public

    func start() {
        guard !isRunning else { return }
        NSLog("[MeetingSession] Starting (Cohere STT, background processing)")
        isRunning = true
        segmentCounter = 0
        results = [:]
        pendingCount = 0
        sessionStart = Date()
        isSpeaking = false
        silenceStart = nil
        segmentStart = Date()
        onStatusChange?(true)
        if AppSettings.shared.captureSystemAudio {
            startSystemAudioCapture()
        } else {
            startAudioCapture()
        }
        startVADTimer()
    }

    func stop() {
        guard isRunning else { return }
        NSLog("[MeetingSession] Stopping — flushing final segment and waiting for results")
        isRunning = false
        vadTimer?.invalidate()
        vadTimer = nil

        // Stop audio
        if AppSettings.shared.captureSystemAudio {
            Task { await SystemAudioCapture.shared.stopCapture() }
        }
        let finalWAV = stopAudioCapture()
        if let wav = finalWAV {
            submitSegment(wav)
        }

        onStatusChange?(false)

        // Wait for pending segments, then paste summary only
        Task {
            // Wait for in-flight segments (max 60s)
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                resultsLock.lock()
                let allDone = pendingCount == 0
                resultsLock.unlock()
                if allDone { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            resultsLock.lock()
            let fullTranscript = accumulatedTranscript
            resultsLock.unlock()

            guard !fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSLog("[MeetingSession] No transcript for summary")
                return
            }

            // Request summary via Qwen3
            if AppSettings.shared.meetingSummarize {
                NSLog("[MeetingSession] Requesting summary (%d chars)", fullTranscript.count)
                if let result = await MeetingClient.summarize(transcript: fullTranscript) {
                    var summaryText = "\n---\n"
                    if !result.summary.isEmpty {
                        summaryText += result.summary + "\n"
                    }
                    if !result.actionItems.isEmpty {
                        summaryText += "\n待办:\n" + result.actionItems.map { "- \($0)" }.joined(separator: "\n") + "\n"
                    }
                    await MainActor.run {
                        NSLog("[MeetingSession] Pasting summary")
                        self.injectText(summaryText)
                    }
                }
            }
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture() {
        let engine = AVAudioEngine()
        audioEngine = engine

        pcmLock.lock()
        pcmData = Data()
        pcmLock.unlock()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            NSLog("[MeetingSession] No audio input device")
            isRunning = false; onStatusChange?(false); return
        }

        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard let conv = AVAudioConverter(from: inputFormat, to: outFormat) else {
            NSLog("[MeetingSession] Failed to create converter")
            isRunning = false; onStatusChange?(false); return
        }
        converter = conv

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRunning else { return }

            let rms = self.rms(buffer)
            self.updateVAD(rms: rms)

            let ratio = outFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            var consumed = false
            conv.convert(to: outBuf, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }

            if error == nil, outBuf.frameLength > 0, let ptr = outBuf.int16ChannelData {
                let raw = Data(bytes: ptr.pointee, count: Int(outBuf.frameLength) * 2)
                self.pcmLock.lock()
                self.pcmData.append(raw)
                self.pcmLock.unlock()
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            NSLog("[MeetingSession] Audio capture started")
        } catch {
            NSLog("[MeetingSession] Failed to start audio: %@", "\(error)")
            isRunning = false; onStatusChange?(false)
        }
    }

    /// Start capturing system audio via ScreenCaptureKit (for podcasts, Zoom, etc.)
    private func startSystemAudioCapture() {
        pcmLock.lock()
        pcmData = Data()
        pcmLock.unlock()

        let capture = SystemAudioCapture.shared
        capture.onPCMData = { [weak self] data, rms in
            guard let self = self, self.isRunning else { return }
            self.updateVAD(rms: rms)
            self.pcmLock.lock()
            self.pcmData.append(data)
            self.pcmLock.unlock()
        }

        Task {
            do {
                try await capture.startCapture()
                NSLog("[MeetingSession] System audio capture started")
            } catch {
                NSLog("[MeetingSession] System audio failed: %@", "\(error)")
                await MainActor.run {
                    self.isRunning = false
                    self.onStatusChange?(false)
                }
            }
        }
    }

    private func stopAudioCapture() -> Data? {
        if let engine = audioEngine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            engine.stop()
        }
        audioEngine = nil; converter = nil

        pcmLock.lock()
        let raw = pcmData; pcmData = Data()
        pcmLock.unlock()

        let minBytes = Int(16000 * 1.0) * 2
        guard raw.count >= minBytes else { return nil }
        return buildWAV(pcm: raw)
    }

    private func harvestSegment() -> Data? {
        pcmLock.lock()
        let raw = pcmData; pcmData = Data()
        pcmLock.unlock()

        let minBytes = Int(16000 * 1.0) * 2
        guard raw.count >= minBytes else { return nil }
        return buildWAV(pcm: raw)
    }

    // MARK: - VAD + Segmentation

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        let p = data.pointee
        for i in 0..<n { sum += p[i] * p[i] }
        return min(sqrt(sum / Float(n)) * 5.0, 1.0)
    }

    private func updateVAD(rms: Float) {
        if rms > silenceThreshold {
            isSpeaking = true; silenceStart = nil
        } else if isSpeaking && silenceStart == nil {
            silenceStart = Date()
        }
    }

    private func startVADTimer() {
        vadTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkVAD()
        }
    }

    private func checkVAD() {
        guard isRunning, let start = segmentStart else { return }
        let elapsed = Date().timeIntervalSince(start)

        // Force flush at max duration
        if elapsed >= maxSegmentDuration {
            NSLog("[MeetingSession] Max duration (%.0fs), flushing", elapsed)
            flushCurrentSegment()
            return
        }

        // Only consider flushing after minimum segment duration
        guard elapsed >= minSegmentSeconds else { return }

        // Flush on speech pause
        if isSpeaking, let silence = silenceStart,
           Date().timeIntervalSince(silence) >= silenceDuration {
            NSLog("[MeetingSession] Pause at %.0fs, flushing segment", elapsed)
            flushCurrentSegment()
        }
    }

    private func flushCurrentSegment() {
        guard let wav = harvestSegment() else {
            resetVADState(); return
        }
        let bytes = wav.count
        resetVADState()
        submitSegment(wav)
        NSLog("[MeetingSession] Segment %d submitted (%d bytes)", segmentCounter - 1, bytes)
    }

    private func resetVADState() {
        isSpeaking = false; silenceStart = nil; segmentStart = Date()
    }

    // MARK: - Background Processing

    /// Submit a segment: transcribe via Cohere, paste immediately with timestamp,
    /// and accumulate for final summary.
    private func submitSegment(_ wavData: Data) {
        let seq = segmentCounter
        segmentCounter += 1

        let elapsed = Date().timeIntervalSince(sessionStart ?? Date())
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        let timestamp = String(format: "[%d:%02d]", mins, secs)

        resultsLock.lock()
        pendingCount += 1
        resultsLock.unlock()

        Task {
            let text = await self.transcribeViaCohere(wavData)

            let line: String
            if let text = text, !text.isEmpty {
                line = "\(timestamp) \(text)"
            } else {
                NSLog("[MeetingSession] Segment %d: no transcript (empty or failed)", seq)
                line = ""
            }

            self.resultsLock.lock()
            self.results[seq] = line
            if !line.isEmpty {
                self.accumulatedTranscript += line + "\n"
            }
            self.pendingCount -= 1
            let pending = self.pendingCount
            self.resultsLock.unlock()

            // Paste immediately
            if !line.isEmpty {
                await MainActor.run {
                    NSLog("[MeetingSession] Pasting seg %d: %@", seq, line.prefix(60) as CVarArg)
                    self.injectText(line + "\n")
                }
            }

            NSLog("[MeetingSession] Segment %d done, %d pending", seq, pending)
        }
    }

    /// Use Cohere STT (same endpoint as normal voice input) for transcription.
    private func transcribeViaCohere(_ wavData: Data) async -> String? {
        let settings = AppSettings.shared
        guard !settings.sttEndpoint.isEmpty, !settings.sttAPIKey.isEmpty else {
            NSLog("[MeetingSession] No STT endpoint configured")
            return nil
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(settings.selectedLanguage)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n0\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n--\(boundary)--\r\n")

        guard let url = URL(string: settings.sttEndpoint) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(settings.sttAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            NSLog("[MeetingSession] Cohere STT error: %@", "\(error)")
        }
        return nil
    }

    // MARK: - Text Injection

    private func injectText(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        usleep(50_000)
        let src = CGEventSource(stateID: .combinedSessionState)
        if let d = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) {
            d.flags = .maskCommand; d.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let u = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) {
            u.flags = .maskCommand; u.post(tap: .cgAnnotatedSessionEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pb.clearContents()
            if let s = saved { pb.setString(s, forType: .string) }
        }
    }

    // MARK: - WAV Builder

    private func buildWAV(pcm: Data) -> Data {
        var wav = Data()
        let dataSize = UInt32(pcm.count)
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: (36 + dataSize).littleEndian) { Data($0) })
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt32(16000).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt32(32000).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        wav.append("data".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wav.append(pcm)
        return wav
    }
}
