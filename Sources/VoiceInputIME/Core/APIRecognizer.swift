import Foundation
import AVFoundation

/// Records audio and sends to the self-hosted STT API for transcription.
final class APIRecognizer {
    var onAudioLevel: ((Float) -> Void)?

    private let endpoint = "https://stt.borui.ca/v1/audio/transcriptions"
    private let token = "RZpLK0h7Fs9McBfMNFfjuLFK5nuC5gVYbxDptbmtbzc"

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempURL: URL?
    private var isRecording = false
    private var tapInstalled = false
    private var recordingStartTime: TimeInterval = 0

    // MARK: - Start

    func startRecording() throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        audioEngine = engine

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("vi_\(Int(Date().timeIntervalSince1970)).wav")
        tempURL = url

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw RecordingError.noInputDevice
        }

        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                sampleRate: 16000, channels: 1, interleaved: true)!
        audioFile = try AVAudioFile(forWriting: url, settings: fmt.settings)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            if let converted = self.convert(buffer, to: fmt) {
                try? self.audioFile?.write(from: converted)
            }
            let level = self.rms(buffer)
            DispatchQueue.main.async { self.onAudioLevel?(level) }
        }
        tapInstalled = true

        // Handle hardware configuration changes (headphones disconnect, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )

        engine.prepare()
        try engine.start()
        isRecording = true
        recordingStartTime = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Stop

    /// Returns transcribed text, or empty string if recording was too short or failed.
    /// - Parameter context: Recent text typed by the user — passed to Whisper as prompt for better accuracy.
    func stopRecording(context: String = "") async -> String {
        guard isRecording else { return "" }
        isRecording = false
        let duration = ProcessInfo.processInfo.systemUptime - recordingStartTime

        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: audioEngine)

        if let engine = audioEngine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
        }
        audioEngine = nil
        audioFile = nil  // flush & close

        guard let url = tempURL else { return "" }
        tempURL = nil
        defer { try? FileManager.default.removeItem(at: url) }

        guard let data = try? Data(contentsOf: url) else { return "" }

        // Require at least ~0.3s of 16kHz mono s16 audio (header=44 bytes + ~9600 samples)
        let minBytes = 44 + 16000 * 2 / 3
        guard data.count > minBytes else {
            NSLog("[APIRecognizer] Recording too short (%d bytes), skipping", data.count)
            return ""
        }

        let result = await transcribeWithRetry(data, context: context, temperature: 0)

        // Low confidence check: very few chars for a long recording → retry at higher temp
        let charsPerSecond = Double(result.count) / max(duration, 0.1)
        if duration > 2.0 && charsPerSecond < 1.5 && !result.isEmpty {
            NSLog("[APIRecognizer] Low confidence (%.1f chars/s), retrying at temp=0.4", charsPerSecond)
            let retry = await transcribeWithRetry(data, context: context, temperature: 0.4)
            return retry.count > result.count ? retry : result
        }

        return result
    }

    // MARK: - Upload

    private func transcribeWithRetry(_ audioData: Data, context: String, temperature: Double, attempt: Int = 1) async -> String {
        let result = await transcribe(audioData, context: context, temperature: temperature)
        if result.isEmpty && attempt < 2 {
            NSLog("[APIRecognizer] Retrying STT (attempt %d)...", attempt + 1)
            try? await Task.sleep(nanoseconds: 500_000_000)
            return await transcribeWithRetry(audioData, context: context, temperature: temperature, attempt: attempt + 1)
        }
        return result
    }

    private func transcribe(_ audioData: Data, context: String, temperature: Double) async -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\nzh\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n\(temperature)\r\n")
        if !context.isEmpty {
            append("--\(boundary)\r\n")
            // Whisper prompt: last ~224 tokens worth of context (keep it short)
            let trimmed = String(context.suffix(300))
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\(trimmed)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                NSLog("[APIRecognizer] HTTP %d: %@", statusCode, String(data: data, encoding: .utf8) ?? "")
                return ""
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[APIRecognizer] ✓ %@", trimmed)
                return trimmed
            }
            NSLog("[APIRecognizer] Unexpected response: %@", String(data: data, encoding: .utf8) ?? "?")
        } catch {
            NSLog("[APIRecognizer] Request failed: %@", "\(error)")
        }
        return ""
    }

    // MARK: - Engine Config Change

    @objc private func handleEngineConfigChange(_ notification: Notification) {
        guard isRecording, let engine = audioEngine else { return }
        NSLog("[APIRecognizer] Audio engine config changed, restarting...")
        do {
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("[APIRecognizer] Failed to restart engine: %@", "\(error)")
            isRecording = false
        }
    }

    // MARK: - Audio Utilities

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 1)) else { return nil }

        var done = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData; done = true
            return buffer
        }
        return err == nil ? out : nil
    }

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

enum RecordingError: LocalizedError {
    case noInputDevice
    var errorDescription: String? { "No audio input device available." }
}
