import Foundation
import AVFoundation
import os.log

private let cloudLog = Logger(subsystem: "com.voiceinput.app", category: "CloudSTT")

/// Cloud-based STT engine. Sends recorded audio to a remote API endpoint.
final class CloudSTTEngine: STTEngine {
    var onAudioLevel: ((Float) -> Void)?
    var onPartialTranscript: ((String) -> Void)?

    private var capture = AudioCaptureSession()
    private var isRecording = false
    private var recordingStartTime: TimeInterval = 0
    private var pcmData = Data()
    private let pcmLock = NSLock()
    private var converter: AVAudioConverter?
    private var recordingLanguage = "zh"

    // MARK: - STTEngine

    func startRecording(language: String) throws {
        guard !isRecording else { return }
        recordingLanguage = language

        pcmLock.lock()
        pcmData = Data()
        pcmLock.unlock()

        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        var setupError: Error?
        var captureConverter: AVAudioConverter?

        let cfg = AudioCaptureSession.Config(
            onBuffer: { [weak self] buffer, inputFormat in
                guard let self = self, self.isRecording else { return }
                guard let conv = captureConverter else { return }
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
            },
            onLevel: { [weak self] level in
                self?.onAudioLevel?(level)
            },
            bufferSize: 4096
        )

        let inputFormat = try capture.start(config: cfg)
        guard let conv = AVAudioConverter(from: inputFormat, to: outFormat) else {
            capture.stop()
            throw STTError.noInputDevice
        }
        captureConverter = conv
        converter = conv

        isRecording = true
        recordingStartTime = ProcessInfo.processInfo.systemUptime
    }

    func stopRecording(context: String) async -> Result<String, STTError> {
        guard let wavData = stopRecordingRaw() else { return .success("") }
        return await transcribeWithRetry(wavData, context: context)
    }

    private func stopRecordingRaw() -> Data? {
        guard isRecording else { return nil }
        isRecording = false

        capture.stop()
        converter = nil

        pcmLock.lock()
        let raw = pcmData; pcmData = Data()
        pcmLock.unlock()

        let minBytes = Int(16000 * 0.3) * 2
        guard raw.count >= minBytes else {
            cloudLog.warning("Recording too short (\(raw.count) bytes)")
            return nil
        }

        return buildWAV(pcm: raw)
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

    private func transcribeWithRetry(_ audioData: Data, context: String) async -> Result<String, STTError> {
        var lastError: STTError = .engineUnavailable
        for attempt in 1...3 {
            let result = await transcribe(audioData, context: context)
            switch result {
            case .success(let text):
                if !text.isEmpty { return .success(text) }
                return .success(text)
            case .failure(let err):
                lastError = err
                if case .notConfigured = err { return .failure(err) }
                cloudLog.warning("Attempt \(attempt)/3 failed: \(err.userMessage, privacy: .public), retrying…")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
            }
        }
        return .failure(lastError)
    }

    private func transcribe(_ audioData: Data, context: String) async -> Result<String, STTError> {
        let settings = AppSettings.shared
        guard !settings.sttEndpoint.isEmpty, !settings.sttAPIKey.isEmpty else {
            cloudLog.error("No endpoint or API key configured")
            return .failure(.notConfigured)
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

        guard let url = URL(string: settings.sttEndpoint) else {
            return .failure(.notConfigured)
        }
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
                cloudLog.error("HTTP \(code)")
                return .failure(.http(code))
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                cloudLog.info("result: \(trimmed, privacy: .private)")
                return .success(trimmed)
            }
            cloudLog.error("Failed to parse STT response")
            return .failure(.parseFailure)
        } catch {
            cloudLog.error("\(error, privacy: .public)")
            return .failure(.network(error.localizedDescription))
        }
    }
}
