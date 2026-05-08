import AVFoundation
import Foundation
import os.log

private let mtLog = Logger(subsystem: "com.voiceinput.app", category: "MeetingTranscriber")

/// Continuous meeting-notes transcriber. Records audio in the background,
/// transcribes ~minute-long chunks via the Cloud STT endpoint, and appends
/// each result with a timestamp to a single Markdown file for the session.
///
/// One file per session (start → stop). Filename:
///   `meeting-YYYYMMDD-HHmmss.md`
///
/// Independent of the dictation hotkey (`RecordingSession`). Both can run
/// concurrently — they each own a separate `AVAudioEngine` tap.
final class MeetingTranscriber {
    static let shared = MeetingTranscriber()

    private let queue = DispatchQueue(label: "com.voiceinput.meeting", qos: .utility)
    private let pcmLock = NSLock()
    private var pcmBuffer = Data()
    private var chunkTimer: DispatchSourceTimer?
    private let capture = AudioCaptureSession()
    private var converter: AVAudioConverter?

    /// Active session's markdown file path. nil while stopped.
    private var sessionURL: URL?
    private var sessionStartedAt: Date?
    /// Sequential chunk index, used only for log lines.
    private var chunkIndex = 0

    /// Cut a chunk every N seconds. Shorter = finer paragraph granularity but
    /// more network traffic. 60 s is a reasonable meeting-notes default.
    var chunkInterval: TimeInterval = 60.0

    private(set) var isRunning = false

    private init() {}

    // MARK: - Public

    func start(folder: URL) throws {
        let outcome: Result<Void, Error> = queue.sync {
            if isRunning { return .success(()) }
            // Cloud STT must be configured — Apple Speech doesn't fit the
            // chunked-WAV pattern cleanly and Whisper local isn't implemented.
            let s = AppSettings.shared
            guard !s.sttEndpoint.isEmpty, !s.sttAPIKey.isEmpty else {
                return .failure(STTError.notConfigured)
            }
            do {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try openSessionFile(in: folder)
                try startCapture()
                startChunkTimer()
                isRunning = true
                mtLog.info("Started, file=\(self.sessionURL?.lastPathComponent ?? "?", privacy: .public)")
                return .success(())
            } catch {
                mtLog.error("Start failed: \(error.localizedDescription, privacy: .public)")
                cleanup()
                return .failure(error)
            }
        }
        if case .failure(let err) = outcome { throw err }
    }

    func stop() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false
            chunkTimer?.cancel()
            chunkTimer = nil
            // Final flush of whatever's still in the buffer.
            flushChunk(final: true)
            capture.stop()
            converter = nil
            // Append a closing marker, then leave the file alone.
            appendToFile("\n_— end of session —_\n")
            sessionURL = nil
            sessionStartedAt = nil
            chunkIndex = 0
            mtLog.info("Stopped")
        }
    }

    // MARK: - Capture

    private func startCapture() throws {
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16000,
                                            channels: 1,
                                            interleaved: true) else {
            throw STTError.noInputDevice
        }

        let inputFormat = try capture.start(config: AudioCaptureSession.Config(
            onBuffer: { [weak self] buffer, format in
                self?.handle(buffer: buffer, inputFormat: format, outFormat: outFormat)
            },
            onLevel: { _ in },
            bufferSize: 4096
        ))
        converter = AVAudioConverter(from: inputFormat, to: outFormat)
        if converter == nil { throw STTError.noInputDevice }
    }

    private func handle(buffer: AVAudioPCMBuffer,
                        inputFormat: AVAudioFormat,
                        outFormat: AVAudioFormat) {
        guard let conv = self.converter else { return }
        let ratio = outFormat.sampleRate / inputFormat.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }

        var error: NSError?
        var consumed = false
        conv.convert(to: outBuf, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, outBuf.frameLength > 0, let ptr = outBuf.int16ChannelData else { return }
        let data = Data(bytes: ptr.pointee, count: Int(outBuf.frameLength) * 2)
        pcmLock.lock()
        pcmBuffer.append(data)
        pcmLock.unlock()
    }

    // MARK: - Chunk rotation + transcription

    private func startChunkTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + chunkInterval, repeating: chunkInterval)
        timer.setEventHandler { [weak self] in self?.flushChunk(final: false) }
        timer.resume()
        chunkTimer = timer
    }

    private func flushChunk(final: Bool) {
        pcmLock.lock()
        let pcm = pcmBuffer
        pcmBuffer = Data()
        pcmLock.unlock()

        // Skip near-empty chunks (less than 1 s of audio).
        let minBytes = Int(16000 * 1.0) * 2
        guard pcm.count >= minBytes else {
            if final { mtLog.info("Final chunk skipped — too short") }
            return
        }

        let idx = chunkIndex
        chunkIndex += 1
        let timestamp = MeetingTranscriber.timeOfDay(Date())
        let wav = MeetingTranscriber.wavData(pcm: pcm)

        // Transcribe off-thread; queue.async so we don't block the chunk
        // timer from rolling the next interval.
        Task.detached(priority: .utility) { [weak self] in
            await self?.transcribeAndAppend(wav: wav, timestamp: timestamp, idx: idx)
        }
    }

    private func transcribeAndAppend(wav: Data, timestamp: String, idx: Int) async {
        let text = await MeetingTranscriber.transcribe(wav: wav)
        guard !text.isEmpty else {
            mtLog.info("Chunk \(idx) returned empty")
            return
        }
        // Trailing newline so consecutive chunks each get their own block.
        let line = "**[\(timestamp)]** \(text)\n\n"
        queue.async { [weak self] in
            self?.appendToFile(line)
        }
    }

    // MARK: - File IO

    private func openSessionFile(in folder: URL) throws {
        let stamp = Self.sessionStamp()
        let url = folder.appendingPathComponent("meeting-\(stamp).md")
        let header = """
        # Meeting Notes — \(Self.headerStamp())

        _Auto-transcribed by VoiceInput. Each block prefixed with capture timestamp._

        """
        try header.data(using: .utf8)?.write(to: url)
        sessionURL = url
        sessionStartedAt = Date()
    }

    /// Synchronous append on `queue`. Cheap for small lines; if the file is
    /// gigantic later, swap to a long-lived FileHandle.
    private func appendToFile(_ s: String) {
        guard let url = sessionURL, let data = s.data(using: .utf8) else { return }
        do {
            let fh = try FileHandle(forWritingTo: url)
            try fh.seekToEnd()
            try fh.write(contentsOf: data)
            try fh.close()
        } catch {
            mtLog.error("Append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cleanup() {
        chunkTimer?.cancel()
        chunkTimer = nil
        capture.stop()
        converter = nil
        pcmLock.lock()
        pcmBuffer = Data()
        pcmLock.unlock()
        sessionURL = nil
        sessionStartedAt = nil
        chunkIndex = 0
    }

    // MARK: - WAV encoder (16 kHz mono int16)

    private static func wavData(pcm: Data) -> Data {
        var d = Data()
        let dataSize = UInt32(pcm.count)
        d.append("RIFF".data(using: .ascii)!)
        d.append(withUnsafeBytes(of: (36 + dataSize).littleEndian) { Data($0) })
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: UInt32(16000).littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: UInt32(32000).littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        d.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        d.append("data".data(using: .ascii)!)
        d.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        d.append(pcm)
        return d
    }

    // MARK: - Cloud STT call

    /// Send a WAV blob to the configured Cloud STT endpoint (OpenAI-Whisper-
    /// compatible /audio/transcriptions). Returns the transcribed text or "".
    private static func transcribe(wav: Data) async -> String {
        let s = AppSettings.shared
        guard !s.sttEndpoint.isEmpty,
              let url = URL(string: s.sttEndpoint) else { return "" }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ str: String) { body.append(str.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(s.selectedLanguage)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n0\r\n")
        if !s.sttModel.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"model\"\r\n\r\n\(s.sttModel)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"meeting.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !s.sttAPIKey.isEmpty {
            req.setValue("Bearer \(s.sttAPIKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else { return "" }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            mtLog.error("Cloud STT failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    // MARK: - Stamps

    private static func sessionStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func headerStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    private static func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
