import Foundation
import Speech
import AVFoundation

/// Keyboard-extension speech recorder using the **file-based** path.
///
/// Why not AVAudioEngine: keyboard extensions can run `AVAudioEngine`, but on iOS 17+ real
/// devices the engine throws an opaque CoreAudio error (`com.apple.coreaudio.avfaudio`,
/// OSStatus 'what' / 2003329396) during `engine.start()`. Apple's documented path that
/// works reliably in extensions is `AVAudioRecorder` writing to a temporary file, then
/// passing the URL to `SFSpeechURLRecognitionRequest` after recording ends.
///
/// Tradeoff: transcription happens only on release (no streaming partials), but the keyboard
/// is a press-and-hold UX anyway, so this matches user expectations.
@MainActor
final class KeyboardRecorder: ObservableObject {

    enum State: Equatable {
        case idle
        case requestingAuth
        case recording
        case transcribing
        case error(String)
    }

    @Published private(set) var state: State = .idle

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    // MARK: - Public control

    func startIfNeeded() {
        guard state == .idle || isErrorState else { return }
        ensureAuthorized { [weak self] authorized in
            guard let self else { return }
            guard authorized else {
                self.state = .error("Permission denied — enable mic + speech")
                return
            }
            do {
                try self.startRecording()
                self.state = .recording
            } catch let e as NSError {
                let msg = "\(e.domain)#\(e.code): \(e.localizedDescription)"
                self.state = .error(String(msg.prefix(80)))
            }
        }
    }

    func stopAndTranscribe(completion: @escaping (String) -> Void) {
        guard state == .recording else {
            completion("")
            return
        }
        state = .transcribing

        audioRecorder?.stop()
        audioRecorder = nil

        // Audio session: deactivate so we don't hog the mic while transcribing.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = recordingURL, FileManager.default.fileExists(atPath: url.path) else {
            self.state = .idle
            completion("")
            return
        }

        transcribe(url: url) { [weak self] text in
            guard let self else { return }
            try? FileManager.default.removeItem(at: url)
            self.recordingURL = nil
            self.state = .idle
            completion(text)
        }
    }

    // MARK: - Auth

    private var isErrorState: Bool {
        if case .error = state { return true } else { return false }
    }

    private func ensureAuthorized(_ completion: @escaping (Bool) -> Void) {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micGranted = AVAudioSession.sharedInstance().recordPermission == .granted

        func afterSpeech(_ ok: Bool) {
            guard ok else { completion(false); return }
            if micGranted {
                completion(true)
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async { completion(granted) }
                }
            }
        }

        switch speechStatus {
        case .authorized:
            afterSpeech(true)
        case .notDetermined:
            state = .requestingAuth
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { afterSpeech(status == .authorized) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Recording

    private func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        // Keyboard extensions on iOS 17/18 real devices need .playAndRecord with specific
        // options — the plain .record category causes setActive(true) to silently no-op,
        // which makes AVAudioRecorder.record() return false.
        try session.setCategory(.playAndRecord,
                                mode: .default,
                                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // AAC in an m4a container — more compatible with SFSpeechURLRecognitionRequest
        // than raw linear PCM when the audio session is doing format conversion.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceinput-\(UUID().uuidString).m4a")

        let recorder = try AVAudioRecorder(url: tmp, settings: settings)
        recorder.isMeteringEnabled = false
        guard recorder.prepareToRecord() else {
            throw NSError(domain: "VoiceInput", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "prepareToRecord=false"])
        }
        guard recorder.record() else {
            let micState = AVAudioSession.sharedInstance().recordPermission
            let micStr: String
            switch micState {
            case .granted: micStr = "mic=granted"
            case .denied: micStr = "mic=denied"
            case .undetermined: micStr = "mic=undetermined"
            @unknown default: micStr = "mic=?"
            }
            let cat = AVAudioSession.sharedInstance().category.rawValue
            throw NSError(domain: "VoiceInput", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "record()=false \(micStr) cat=\(cat)"])
        }
        self.audioRecorder = recorder
        self.recordingURL = tmp
    }

    // MARK: - Transcription

    private func transcribe(url: URL, completion: @escaping (String) -> Void) {
        let preferred = SharedSettings.language
        let candidates = [preferred, "en-US", Locale.current.identifier]
        var chosen: SFSpeechRecognizer?
        for id in candidates {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable {
                chosen = r
                break
            }
        }
        guard let rec = chosen else {
            DispatchQueue.main.async {
                self.state = .error("Recognizer unavailable")
                completion("")
            }
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        rec.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { completion(text) }
            } else if let error {
                DispatchQueue.main.async {
                    self.state = .error("STT: \(error.localizedDescription.prefix(60))")
                    completion("")
                }
            }
        }
    }
}
