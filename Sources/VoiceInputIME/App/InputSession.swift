import Cocoa
import InputMethodKit

/// One InputSession per client app. Manages voice recording state and text commitment.
final class InputSession {
    // MARK: - Session Cache
    private static var sessions = NSMapTable<AnyObject, InputSession>.weakToStrongObjects()

    static func session(for client: any IMKTextInput) -> InputSession {
        let key = client as AnyObject
        if let existing = sessions.object(forKey: key) { return existing }
        let session = InputSession()
        sessions.setObject(session, forKey: key)
        return session
    }

    // MARK: - Shared Components
    private static let recognizer = APIRecognizer()
    private static let audioLevelProvider = AudioLevelProvider()
    private static let textPostProcessor = TextPostProcessor()
    private static let llmRefiner = LLMRefiner()
    private static let vocabDB = VocabularyDB.shared
    private static let floatingPanel = FloatingPanel()

    private var settings: AppSettings { AppSettings.shared }

    // MARK: - State
    private var state: RecognitionState = .idle
    private var optionDown = false
    private var optionDownTime: TimeInterval = 0
    private var holdFired = false
    private let tapThreshold: TimeInterval = 0.3

    // Silence detection
    private let silenceThreshold: Float = 0.02
    private let silenceTimeout: TimeInterval = 3.0
    private var silenceTimer: Timer?
    private var lastSpeechTime: TimeInterval = 0

    private weak var activeClient: (any IMKTextInput)?

    // Track the active transcription task so cancel can abort it
    private var activeTask: Task<Void, Never>?

    // Rolling context buffer: last ~500 chars of committed text for STT prompt + LLM
    private var contextBuffer = ""
    private let maxContextLength = 500

    private func addContext(_ text: String) {
        contextBuffer += text + " "
        if contextBuffer.count > maxContextLength {
            contextBuffer = String(contextBuffer.suffix(maxContextLength))
        }
    }

    // MARK: - Event Handling

    func handleEvent(_ event: NSEvent, client: any IMKTextInput) -> Bool {
        // Escape cancels recording or pending transcription
        if event.type == .keyDown && event.keyCode == 53 {
            if state.isRecording || state.isRefining {
                cancelComposition(client: client)
                return true
            }
        }

        // Option key → voice
        if event.type == .flagsChanged {
            let kc = event.keyCode
            if kc == 58 || kc == 61 {
                return handleOptionKey(event: event, client: client)
            }
            return false
        }

        // Swallow keys while recording or refining
        if state.isRecording || state.isRefining { return true }

        return false
    }

    // MARK: - Option Key

    private func handleOptionKey(event: NSEvent, client: any IMKTextInput) -> Bool {
        let isDown = event.modifierFlags.contains(.option)

        if isDown && !optionDown {
            optionDown = true
            optionDownTime = ProcessInfo.processInfo.systemUptime
            // Start recording immediately on press
            startRecording(client: client, mode: .hold)
            return true

        } else if !isDown && optionDown {
            optionDown = false
            let duration = ProcessInfo.processInfo.systemUptime - optionDownTime

            if duration < tapThreshold {
                // Quick tap: cancel hold recording, toggle continuous instead
                cancelRecording()
                if state.isIdle {
                    startRecording(client: client, mode: .continuous)
                }
            } else {
                // Hold release: finish and send
                finishRecording(client: client)
            }
            return true
        }

        return false
    }

    // MARK: - Composition

    func composedString() -> String { state.displayText }

    func commitComposition(client: any IMKTextInput) {
        if case .recording(let text, _) = state, !text.isEmpty {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        cancelRecording()
    }

    func cancelComposition(client: any IMKTextInput) {
        cancelRecording()
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - Recording

    private func handleTap(client: any IMKTextInput) {
        if state.isRecording { finishRecording(client: client) }
        else if state.isIdle { startRecording(client: client, mode: .continuous) }
    }

    private func startRecording(client: any IMKTextInput, mode: InputMode) {
        guard state.isIdle else { return }

        activeClient = client
        state = .recording(partialText: "", mode: mode)
        Self.audioLevelProvider.reset()
        lastSpeechTime = ProcessInfo.processInfo.systemUptime

        Self.floatingPanel.updateContent(text: "🎤", audioLevel: 0, isContinuousMode: mode == .continuous)
        Self.floatingPanel.showWithAnimation()

        if mode == .continuous { startSilenceDetection() }

        Self.recognizer.onAudioLevel = { [weak self] level in
            self?.handleAudioLevel(level)
        }

        do {
            try Self.recognizer.startRecording()
        } catch {
            NSLog("[InputSession] Failed to start recording: %@", "\(error)")
            stopSilenceDetection()
            state = .idle
            Self.floatingPanel.hideWithAnimation()
        }
    }

    private func finishRecording(client: any IMKTextInput) {
        guard state.isRecording else { return }

        stopSilenceDetection()
        state = .refining(text: "")
        Self.floatingPanel.updateContent(text: "", audioLevel: 0, isRefining: true)

        // Capture client strongly for the async task
        let capturedClient = client

        activeTask = Task { [weak self] in
            guard let self = self else { return }

            let rawText = await Self.recognizer.stopRecording(context: self.contextBuffer)

            // If cancelled (state changed to idle) while waiting, bail out
            guard !Task.isCancelled, self.state.isRefining else {
                NSLog("[InputSession] Task cancelled after STT")
                return
            }

            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run {
                    self.state = .idle
                    Self.floatingPanel.hideWithAnimation()
                    capturedClient.setMarkedText("",
                        selectionRange: NSRange(location: 0, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                return
            }

            // Vocab corrections
            let (vocabCorrected, applied) = Self.vocabDB.applyCorrections(rawText)
            for (orig, corr) in applied {
                Self.vocabDB.learn(original: orig, corrected: corr, source: "usage")
            }

            let processed = Self.textPostProcessor.process(vocabCorrected)

            let refined = await Self.llmRefiner.refine(text: processed, context: self.contextBuffer, settings: self.settings)
            guard !Task.isCancelled, self.state.isRefining else { return }
            if refined != processed {
                Self.vocabDB.learnFromDiff(original: rawText, corrected: refined, source: "ai")
            }
            await MainActor.run {
                self.addContext(refined)
                self.commitText(refined, client: capturedClient)
            }
        }
    }

    private func commitText(_ text: String, client: any IMKTextInput) {
        guard state.isRefining else { return }  // Guard against stale commits
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        state = .idle
        Self.floatingPanel.hideWithAnimation()

        if settings.autoSend {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.simulateSend() }
        }
    }

    private func cancelRecording() {
        stopSilenceDetection()
        activeTask?.cancel()
        activeTask = nil
        Task { _ = await Self.recognizer.stopRecording() }
        state = .idle
        Self.floatingPanel.hideWithAnimation()
    }

    // MARK: - Auto-Send

    private func simulateSend() {
        let source = CGEventSource(stateID: .hidSystemState)
        let needsCmd = isFrontAppWeChat()
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) {
            if needsCmd { down.flags = .maskCommand }
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
            if needsCmd { up.flags = .maskCommand }
            up.post(tap: .cghidEventTap)
        }
    }

    private func isFrontAppWeChat() -> Bool {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return id.contains("com.tencent.xinWeChat") || id.contains("com.tencent.WeWorkMac")
    }

    // MARK: - Silence Detection

    private func startSilenceDetection() {
        stopSilenceDetection()
        lastSpeechTime = ProcessInfo.processInfo.systemUptime
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }
    }

    private func stopSilenceDetection() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    private func checkSilence() {
        guard case .recording(let text, .continuous) = state else { stopSilenceDetection(); return }
        if ProcessInfo.processInfo.systemUptime - lastSpeechTime >= silenceTimeout
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let client = activeClient { finishRecording(client: client) }
        }
    }

    // MARK: - Audio Level

    private func handleAudioLevel(_ level: Float) {
        Self.audioLevelProvider.update(rawLevel: level)
        if level > silenceThreshold { lastSpeechTime = ProcessInfo.processInfo.systemUptime }

        if case .recording(_, let mode) = state {
            Self.floatingPanel.updateContent(
                text: "🎤",
                audioLevel: Self.audioLevelProvider.smoothedLevel,
                isContinuousMode: mode == .continuous
            )
        }
    }
}
