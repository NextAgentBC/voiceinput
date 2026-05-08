import AVFoundation
import os.log

private let audioLog = Logger(subsystem: "com.voiceinput.app", category: "AudioCapture")

/// Shared audio capture helper. Installs a single tap on AVAudioEngine's
/// input node, computes RMS, and fans out to callers via Config callbacks.
/// Both AppleSpeechEngine and CloudSTTEngine use this instead of duplicating
/// AVAudioEngine setup and RMS logic.
final class AudioCaptureSession {
    struct Config {
        /// Called off-main with each raw input buffer and the input format.
        let onBuffer: (AVAudioPCMBuffer, AVAudioFormat) -> Void
        /// Called on main with the RMS level (0–1) for every buffer.
        let onLevel: (Float) -> Void
        /// AVAudio tap buffer size.
        var bufferSize: AVAudioFrameCount = 4096
    }

    private var engine: AVAudioEngine?
    private var tapInstalled = false

    /// Start capturing. Returns the input format so the caller can configure
    /// downstream converters. Throws `STTError.noInputDevice` on failure.
    @discardableResult
    func start(config: Config) throws -> AVAudioFormat {
        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw STTError.noInputDevice }

        inputNode.installTap(onBus: 0, bufferSize: config.bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard self != nil else { return }
            let level = AudioCaptureSession.rms(buffer)
            config.onBuffer(buffer, inputFormat)
            DispatchQueue.main.async { config.onLevel(level) }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        audioLog.info("Started capture, sampleRate=\(inputFormat.sampleRate, privacy: .public)")
        return inputFormat
    }

    func stop() {
        if let engine = engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
        }
        engine = nil
        audioLog.info("Stopped capture")
    }

    /// Root-mean-square of a float PCM buffer, scaled to 0–1.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        let p = data.pointee
        for i in 0..<n { sum += p[i] * p[i] }
        return min(sqrt(sum / Float(n)) * 5.0, 1.0)
    }
}
