import AVFoundation
import Foundation
import os.log

private let recLog = Logger(subsystem: "com.voiceinput.app", category: "AudioRecorder")

/// Continuous background audio recorder. Captures from the default input,
/// converts to 16 kHz int16 mono PCM, and writes a fresh `.wav` every
/// `rotateInterval` seconds into `folderURL`.
///
/// Independent of `RecordingSession` (the dictation pipeline) — uses its own
/// `AVAudioEngine`. macOS allows multiple processes/engines to read from the
/// same input simultaneously, so the dictation hotkey continues to work
/// while this is active.
final class AudioRecorder {
    static let shared = AudioRecorder()

    private let queue = DispatchQueue(label: "com.voiceinput.audiorecorder", qos: .utility)
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var fileHandle: FileHandle?
    private var currentURL: URL?
    private var bytesWritten: UInt32 = 0
    private var rotateTimer: DispatchSourceTimer?
    private var folderURL: URL?

    /// One file every minute by default.
    var rotateInterval: TimeInterval = 60.0

    private(set) var isRunning = false

    private init() {}

    // MARK: - Public

    func start(folder: URL) throws {
        let outcome: Result<Void, Error> = queue.sync {
            if isRunning { return .success(()) }
            self.folderURL = folder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try openEngineAndFile()
                startRotateTimer()
                isRunning = true
                recLog.info("Started, folder=\(folder.path, privacy: .public)")
                return .success(())
            } catch {
                recLog.error("Start failed: \(error.localizedDescription, privacy: .public)")
                cleanup()
                return .failure(error)
            }
        }
        if case .failure(let err) = outcome { throw err }
    }

    func stop() {
        queue.sync {
            guard isRunning else { return }
            cleanup()
            isRunning = false
            recLog.info("Stopped")
        }
    }

    // MARK: - Engine / file lifecycle

    private func openEngineAndFile() throws {
        guard let folder = folderURL else { throw STTError.notConfigured }

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw STTError.noInputDevice }

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16000,
                                            channels: 1,
                                            interleaved: true) else {
            throw STTError.noInputDevice
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw STTError.noInputDevice
        }
        self.converter = conv

        try openFreshFile(in: folder)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, inputFormat: inputFormat, outFormat: outFormat)
        }
        engine.prepare()
        try engine.start()
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

        queue.async { [weak self] in
            guard let self = self, let fh = self.fileHandle else { return }
            do {
                try fh.write(contentsOf: data)
                self.bytesWritten += UInt32(data.count)
            } catch {
                recLog.error("Write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func openFreshFile(in folder: URL) throws {
        let stamp = Self.timestamp()
        let url = folder.appendingPathComponent("voiceinput-\(stamp).wav")
        // Pre-write a placeholder header; we'll patch the data-size when the
        // file rotates or recording stops.
        let header = Self.wavHeader(dataSize: 0)
        try header.write(to: url)
        let fh = try FileHandle(forUpdating: url)
        try fh.seekToEnd()
        self.fileHandle = fh
        self.currentURL = url
        self.bytesWritten = 0
    }

    private func rotateFile() {
        queue.async { [weak self] in
            guard let self = self, self.isRunning, let folder = self.folderURL else { return }
            self.finalizeCurrentFile()
            do {
                try self.openFreshFile(in: folder)
            } catch {
                recLog.error("Rotate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func finalizeCurrentFile() {
        guard let fh = fileHandle, let url = currentURL else { return }
        defer {
            try? fh.close()
            fileHandle = nil
            currentURL = nil
            bytesWritten = 0
        }
        // Patch the WAV header with the actual data size.
        let totalDataBytes = bytesWritten
        let header = Self.wavHeader(dataSize: totalDataBytes)
        do {
            let writer = try FileHandle(forWritingTo: url)
            try writer.seek(toOffset: 0)
            try writer.write(contentsOf: header)
            try writer.close()
        } catch {
            recLog.error("Header patch failed: \(error.localizedDescription, privacy: .public)")
        }
        recLog.info("Closed file (\(totalDataBytes) bytes)")
    }

    private func startRotateTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + rotateInterval, repeating: rotateInterval)
        timer.setEventHandler { [weak self] in self?.rotateFile() }
        timer.resume()
        rotateTimer = timer
    }

    private func cleanup() {
        rotateTimer?.cancel()
        rotateTimer = nil
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        finalizeCurrentFile()
        folderURL = nil
    }

    // MARK: - WAV builder

    /// 44-byte canonical RIFF/WAVE PCM header for 16 kHz mono int16.
    private static func wavHeader(dataSize: UInt32) -> Data {
        var d = Data()
        d.append("RIFF".data(using: .ascii)!)
        d.append(withUnsafeBytes(of: (36 + dataSize).littleEndian) { Data($0) })
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })   // fmt chunk size
        d.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })    // PCM
        d.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })    // mono
        d.append(withUnsafeBytes(of: UInt32(16000).littleEndian) { Data($0) })// sample rate
        d.append(withUnsafeBytes(of: UInt32(32000).littleEndian) { Data($0) })// byte rate
        d.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })    // block align
        d.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })   // bits/sample
        d.append("data".data(using: .ascii)!)
        d.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        return d
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
