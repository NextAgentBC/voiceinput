import Foundation
import ScreenCaptureKit
import AVFoundation

/// Captures system audio (e.g. podcast, Zoom, etc.) via ScreenCaptureKit.
/// Outputs 16kHz mono Int16 PCM data via callback.
final class SystemAudioCapture: NSObject, SCStreamOutput {
    static let shared = SystemAudioCapture()

    /// Called with each chunk of Int16 PCM data + RMS level for VAD.
    var onPCMData: ((Data, Float) -> Void)?

    private var stream: SCStream?
    private(set) var isCapturing = false

    private override init() { super.init() }

    func startCapture() async throws {
        guard !isCapturing else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            NSLog("[SystemAudio] No display found")
            return
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await newStream.startCapture()

        stream = newStream
        isCapturing = true
        NSLog("[SystemAudio] Capture started")
    }

    func stopCapture() async {
        guard isCapturing else { return }
        isCapturing = false
        if let stream = stream { try? await stream.stopCapture() }
        stream = nil
        NSLog("[SystemAudio] Capture stopped")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, isCapturing else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var floatData = Data(count: length)
        floatData.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }

        // ScreenCaptureKit outputs Float32; convert to Int16 + calculate RMS
        let sampleCount = floatData.count / MemoryLayout<Float32>.size
        guard sampleCount > 0 else { return }

        var int16Data = Data(count: sampleCount * 2)
        var rmsSum: Float = 0

        floatData.withUnsafeBytes { srcPtr in
            int16Data.withUnsafeMutableBytes { dstPtr in
                guard let src = srcPtr.baseAddress?.assumingMemoryBound(to: Float32.self),
                      let dst = dstPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                for i in 0..<sampleCount {
                    let s = src[i]
                    rmsSum += s * s
                    let clamped = max(-1.0, min(1.0, s))
                    dst[i] = Int16(clamped * Float32(Int16.max))
                }
            }
        }

        let rms = min(sqrt(rmsSum / Float(sampleCount)) * 5.0, 1.0)
        onPCMData?(int16Data, rms)
    }
}
