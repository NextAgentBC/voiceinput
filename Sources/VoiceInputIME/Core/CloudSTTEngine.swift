import Foundation
import AVFoundation

/// Cloud-based STT engine. Sends recorded audio to a remote API endpoint.
final class CloudSTTEngine: STTEngine {
    var onAudioLevel: ((Float) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private var tapInstalled = false
    private var recordingStartTime: TimeInterval = 0
    private var pcmData = Data()
    private let pcmLock = NSLock()
    private var converter: AVAudioConverter?
    private var recordingLanguage = "zh"

    // MARK: - STTEngine

    func startRecording(language: String) throws {
        guard !isRecording else { return }
        recordingLanguage = language

        let engine = AVAudioEngine()
        audioEngine = engine

        pcmLock.lock()
        pcmData = Data()
        pcmLock.unlock()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw STTError.noInputDevice }

        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard let conv = AVAudioConverter(from: inputFormat, to: outFormat) else { throw STTError.noInputDevice }
        converter = conv

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            let level = self.rms(buffer)
            let ratio = outFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            var consumed = false
            conv.convert(to: outBuf, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }

            if error == nil, outBuf.frameLength > 0, let ptr = outBuf.int16ChannelData {
                let raw = Data(bytes: ptr.pointee, count: Int(outBuf.frameLength) * 2)
                self.pcmLock.lock()
                self.pcmData.append(raw)
                self.pcmLock.unlock()
            }
            DispatchQueue.main.async { self.onAudioLevel?(level) }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        isRecording = true
        recordingStartTime = ProcessInfo.processInfo.systemUptime
    }

    func stopRecording(context: String) async -> String {
        guard isRecording else { return "" }
        isRecording = false

        if let engine = audioEngine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            engine.stop()
        }
        audioEngine = nil
        converter = nil

        pcmLock.lock()
        let raw = pcmData; pcmData = Data()
        pcmLock.unlock()

        let minBytes = Int(16000 * 0.3) * 2
        guard raw.count >= minBytes else {
            NSLog("[CloudSTT] Recording too short (%d bytes)", raw.count)
            return ""
        }

        let wavData = buildWAV(pcm: raw)
        return await transcribeWithRetry(wavData, context: context)
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

    // MARK: - API

    private func transcribeWithRetry(_ audioData: Data, context: String) async -> String {
        for attempt in 1...3 {
            let result = await transcribe(audioData, context: context)
            if !result.isEmpty { return result }
            NSLog("[CloudSTT] Attempt %d/3 failed, retrying...", attempt)
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
        }
        return ""
    }

    private func transcribe(_ audioData: Data, context: String) async -> String {
        let settings = AppSettings.shared
        guard !settings.sttEndpoint.isEmpty, !settings.sttAPIKey.isEmpty else {
            NSLog("[CloudSTT] No endpoint or API key configured")
            return ""
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(recordingLanguage)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n0\r\n")
        if !context.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\(String(context.suffix(300)))\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")

        guard let url = URL(string: settings.sttEndpoint) else { return "" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(settings.sttAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                NSLog("[CloudSTT] HTTP %d", code)
                return ""
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[CloudSTT] \"%@\"", trimmed)
                return trimmed
            }
        } catch {
            NSLog("[CloudSTT] %@", "\(error)")
        }
        return ""
    }

    // MARK: - Audio

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

enum STTError: LocalizedError {
    case noInputDevice
    var errorDescription: String? { "No audio input device available." }
}
