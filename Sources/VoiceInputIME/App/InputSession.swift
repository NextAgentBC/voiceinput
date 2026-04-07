import Cocoa
import Carbon

/// Singleton recording session with pluggable STT engine.
final class RecordingSession {
    static let shared = RecordingSession()

    // MARK: - Engines (lazy-initialized)
    private lazy var appleEngine: STTEngine = AppleSpeechEngine()
    private lazy var cloudEngine: STTEngine = CloudSTTEngine()
    private lazy var whisperEngine: STTEngine = WhisperEngine()

    private var currentEngine: STTEngine {
        switch AppSettings.shared.sttEngineType {
        case .apple: return appleEngine
        case .cloud: return cloudEngine
        case .whisper: return whisperEngine
        }
    }

    // MARK: - Components
    private let audioLevelProvider = AudioLevelProvider()
    private let textPostProcessor = TextPostProcessor()
    private let llmRefiner = LLMRefiner()
    private let vocabDB = VocabularyDB.shared
    private let floatingPanel = FloatingPanel()

    private var settings: AppSettings { AppSettings.shared }

    // MARK: - State
    private var state: RecognitionState = .idle
    private var activeTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    func startRecording() {
        guard state.isIdle else { return }
        NSLog("[Recording] START (engine: %@)", settings.sttEngineType.rawValue)

        state = .recording
        floatingPanel.updateContent(audioLevel: 0)
        floatingPanel.showWithAnimation()

        var engine = currentEngine
        engine.onAudioLevel = { [weak self] level in
            self?.handleAudioLevel(level)
        }

        do {
            try engine.startRecording(language: settings.selectedLanguage)
        } catch {
            NSLog("[Recording] Failed to start: %@", "\(error)")
            state = .idle
            floatingPanel.hideWithAnimation()
        }
    }

    func stopRecording() {
        guard state.isRecording else { return }
        NSLog("[Recording] STOP")

        state = .refining
        floatingPanel.updateContent(audioLevel: 0, isRefining: true)

        let engine = currentEngine

        activeTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let rawText = await engine.stopRecording(context: "")

                guard !Task.isCancelled, self.state.isRefining else { return }

                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        self.state = .idle
                        self.floatingPanel.hideWithAnimation()
                    }
                    return
                }

                // Post-processing pipeline
                let (vocabCorrected, applied) = self.vocabDB.applyCorrections(rawText)
                for (orig, corr) in applied {
                    self.vocabDB.learn(original: orig, corrected: corr, source: "usage")
                }

                let processed = self.textPostProcessor.process(vocabCorrected)

                // Optional LLM refinement
                let refined = await self.llmRefiner.refine(text: processed, context: "", settings: self.settings)
                guard !Task.isCancelled, self.state.isRefining else { return }

                if refined != processed {
                    self.vocabDB.learnFromDiff(original: rawText, corrected: refined, source: "ai")
                }

                await MainActor.run {
                    self.commitText(refined)
                }
            } catch {
                NSLog("[Recording] Error: %@", "\(error)")
                await MainActor.run {
                    self.state = .idle
                    self.floatingPanel.hideWithAnimation()
                }
            }
        }
    }

    func cancelRecording() {
        activeTask?.cancel()
        activeTask = nil
        Task { _ = await currentEngine.stopRecording(context: "") }
        state = .idle
        floatingPanel.hideWithAnimation()
    }

    // MARK: - Text Injection

    private func commitText(_ text: String) {
        guard state.isRefining else { return }
        NSLog("[Recording] Commit: \"%@\"", text)

        state = .idle
        floatingPanel.hideWithAnimation()
        injectText(text)

        if settings.autoSend {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.simulateSend() }
        }
    }

    private func injectText(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // CJK input source handling
        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needSwitch = !isASCIICapable(originalSource)

        if needSwitch, let ascii = findASCIICapableSource() {
            TISSelectInputSource(ascii)
            usleep(50_000)
        }

        // Cmd+V paste
        usleep(50_000)
        let src = CGEventSource(stateID: .combinedSessionState)
        if let d = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) {
            d.flags = .maskCommand; d.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let u = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) {
            u.flags = .maskCommand; u.post(tap: .cgAnnotatedSessionEventTap)
        }

        if needSwitch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { TISSelectInputSource(originalSource) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pb.clearContents()
            if let s = saved { pb.setString(s, forType: .string) }
        }
    }

    // MARK: - CJK Helpers

    private func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }

    private func findASCIICapableSource() -> TISInputSource? {
        let criteria = [kTISPropertyInputSourceIsASCIICapable: true, kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard let list = TISCreateInputSourceList(criteria, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        for s in list {
            if let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
                if id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US" { return s }
            }
        }
        return list.first
    }

    // MARK: - Auto-Send

    private func simulateSend() {
        let src = CGEventSource(stateID: .hidSystemState)
        let cmd = isFrontAppWeChat()
        if let d = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true) {
            if cmd { d.flags = .maskCommand }; d.post(tap: .cghidEventTap)
        }
        if let u = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false) {
            if cmd { u.flags = .maskCommand }; u.post(tap: .cghidEventTap)
        }
    }

    private func isFrontAppWeChat() -> Bool {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return id.contains("com.tencent.xinWeChat") || id.contains("com.tencent.WeWorkMac")
    }

    // MARK: - Audio Level

    private func handleAudioLevel(_ level: Float) {
        audioLevelProvider.update(rawLevel: level)
        if state.isRecording {
            floatingPanel.updateContent(audioLevel: audioLevelProvider.smoothedLevel)
        }
    }
}
