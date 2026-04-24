import Cocoa
import Carbon
import os.log

private let recLog = Logger(subsystem: "com.voiceinput.app", category: "Recording")

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

    var isRefining: Bool { state.isRefining }
    var isRecording: Bool { state.isRecording }

    /// Text we most recently pasted into the foreground app. Used by the
    /// progressive-display flow to know what to undo if the LLM returns a
    /// different refinement, and to detect user edits before they Enter.
    private var lastPastedText: String?

    /// The processed text fed to the LLM for the last utterance — used as
    /// the cache key when promoting a user edit into the cache.
    private var lastProcessedText: String?

    /// Cache key of the most recent LLM refine result.
    private var lastCacheKey: String?
    private var lastCommitAt: Date?
    private let rejectionWindow: TimeInterval = 8

    /// Counter-based "we are injecting" flag. Using a counter (incremented
    /// on each inject, decremented after a short cooldown) avoids the race
    /// where two overlapping paste-backs cause the earlier block's deferred
    /// setter to clear the flag while a later paste is still in flight.
    private var injectingCount: Int = 0
    var isInjecting: Bool { injectingCount > 0 }

    /// True once the user has touched the keyboard or mouse after a paste —
    /// we stop trying to overwrite their text and skip auto-send.
    private var userEditing = false

    private init() {}

    // MARK: - Public API

    func startRecording() {
        guard state.isIdle else { return }
        reportUserRedo()
        PreSendController.shared.cancel()
        // Fresh utterance — any leftover state from a cancelled/interrupted
        // previous pipeline must not leak into this one.
        userEditing = false
        lastPastedText = nil
        lastProcessedText = nil
        lastCacheKey = nil
        activeTask = nil
        recLog.info("START (engine: \(self.settings.sttEngineType.rawValue, privacy: .public))")

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
            recLog.error("Failed to start: \(error, privacy: .public)")
            state = .idle
            floatingPanel.hideWithAnimation()
        }
    }

    func stopRecording() {
        guard state.isRecording else { return }
        recLog.info("STOP")

        state = .refining
        floatingPanel.updateContent(audioLevel: 0, isRefining: true)

        let engine = currentEngine

        activeTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runPipeline(engine: engine)
            // Safety net: whatever path the pipeline took, don't leave the
            // UI stuck in "refining" state.
            await MainActor.run {
                if self.state.isRefining {
                    self.state = .idle
                    self.floatingPanel.hideWithAnimation()
                }
            }
        }
    }

    /// Pipeline:
    ///   1. STT → vocab → post-process.
    ///   2. LLM cache lookup BEFORE pasting — if hit, paste the cached
    ///      refined text directly (correct, instant).
    ///   3. If cache miss, paste the processed text so the user has visual
    ///      feedback, then run the LLM in the background. The LLM's result
    ///      is NOT used to overwrite what was pasted — it only populates the
    ///      cache so the next identical utterance gets the corrected version.
    ///   4. LLM running time doubles as the Esc / edit window: Esc / Cmd+.
    ///      cancels entirely; any keyboard/mouse activity cancels auto-send
    ///      while preserving the pasted text for the user to edit.
    private func runPipeline(engine: STTEngine) async {
        let rawText = await engine.stopRecording(context: "")
        guard !Task.isCancelled, self.state.isRefining else { return }

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await MainActor.run {
                self.state = .idle
                self.floatingPanel.hideWithAnimation()
                self.restoreClipboardIfNeeded()
                // No paste happened, so nothing to keep as lastPastedText.
                self.lastPastedText = nil
                self.lastProcessedText = nil
                self.lastCacheKey = nil
                self.userEditing = false
            }
            return
        }

        let (vocabCorrected, applied) = self.vocabDB.applyCorrections(rawText)
        for (orig, corr) in applied {
            self.vocabDB.learn(original: orig, corrected: corr, source: "usage")
        }
        let processed = self.textPostProcessor.process(vocabCorrected)

        let bundleID = ActiveAppContext.frontmostBundleID
        let profile = bundleID.flatMap { AppProfileStore.shared.profile(for: $0) }

        // Cache hit: paste the refined text directly — no LLM call, no flash.
        if let hit = LLMCache.shared.get(raw: processed, model: settings.llmModel, lang: settings.selectedLanguage) {
            recLog.info("cache hit — paste refined directly")
            await MainActor.run {
                self.injectText(hit.refinedText, preserveClipboard: true)
                self.lastPastedText = hit.refinedText
                self.lastProcessedText = processed
                self.lastCacheKey = hit.key
                self.finalizeCommit(text: hit.refinedText, bundleID: bundleID, profile: profile)
            }
            return
        }

        // Cache miss: paste processed immediately, then run LLM purely to
        // populate the cache. We do NOT overwrite the pasted text with the
        // LLM result — the user asked us not to flash/replace.
        await MainActor.run {
            self.injectText(processed, preserveClipboard: true)
            self.lastPastedText = processed
            self.lastProcessedText = processed
            self.lastCacheKey = nil
        }

        let result = await self.llmRefiner.refine(text: processed, context: "", settings: self.settings)
        guard !Task.isCancelled, self.state.isRefining else { return }

        if result.text != processed {
            self.vocabDB.learnFromDiff(original: rawText, corrected: result.text, source: "ai")
        }

        if self.userEditing {
            recLog.info("User edited during LLM — skipping auto-send")
            await MainActor.run {
                self.state = .idle
                self.floatingPanel.hideWithAnimation()
                self.lastCommitAt = Date()
                // If LLM produced something, cache it keyed by processed for future.
                if result.cacheKey != nil {
                    self.lastCacheKey = result.cacheKey
                }
                // lastPastedText stays — user's pending Enter will read AX and learn.
            }
            return
        }

        await MainActor.run {
            self.finalizeCommit(text: processed, bundleID: bundleID, profile: profile)
        }
    }

    /// Called the moment the user presses any key or clicks mouse that
    /// implies they are editing the pasted text. We stop trying to overwrite
    /// it and stop the auto-send, but preserve `lastPastedText` so that
    /// whenever they finally press Enter we can learn their final version.
    func userStartedEditing() {
        guard lastPastedText != nil, !userEditing else { return }
        recLog.info("User started editing pasted text")
        userEditing = true
        activeTask?.cancel()
        PreSendController.shared.cancel()
        // A cancelled Task may bail out before its own cleanup runs, so the
        // floating panel could otherwise spin forever. Force the state back
        // to idle here.
        if state.isRefining {
            state = .idle
            floatingPanel.hideWithAnimation()
        }
        lastCommitAt = Date()
    }

    func cancelRecording() {
        recLog.info("CANCEL")
        activeTask?.cancel()
        activeTask = nil
        Task { _ = await currentEngine.stopRecording(context: "") }
        state = .idle
        floatingPanel.hideWithAnimation()
        // Paste (if it happened) stays visible. User decides what to do.
        // We clear ALL utterance-scoped state so it doesn't leak into the next one.
        lastPastedText = nil
        lastProcessedText = nil
        lastCacheKey = nil
        lastCommitAt = nil
        userEditing = false
        restoreClipboardIfNeeded()
    }

    // MARK: - Commit finalization

    private func finalizeCommit(text: String, bundleID: String?, profile: AppProfile?) {
        state = .idle
        floatingPanel.hideWithAnimation()
        lastCommitAt = Date()
        recLog.info("Commit: \(text, privacy: .public)")

        // Log this utterance into the session store.
        SessionStore.shared.append(
            rawText: lastProcessedText ?? text,
            finalText: text,
            appBundleID: bundleID,
            appDisplayName: ActiveAppContext.frontmostDisplayName,
            wasCancelled: false
        )

        // Non-blocking: maybe run a background L2 analysis.
        LearningAgent.shared.triggerIfNeeded()

        let shouldAutoSend = profile?.autoSend ?? settings.autoSend
        guard shouldAutoSend else {
            recLog.info("Auto-send skipped (app=\(bundleID ?? "unknown", privacy: .public))")
            restoreClipboardIfNeeded()
            return
        }

        let sendKey = profile?.sendKey ?? settings.sendKey
        let delay = profile?.effectiveDelay(global: settings.autoSendDelay) ?? settings.autoSendDelay

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            PreSendController.shared.schedule(delay: delay, sendKey: sendKey)
        }

        // Restore original clipboard after the send has had time to fire.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.4) {
            self.restoreClipboardIfNeeded()
        }
    }

    // MARK: - Feedback loop for LLM cache

    func reportUserCancelledSend() {
        guard let commitAt = lastCommitAt,
              Date().timeIntervalSince(commitAt) < rejectionWindow,
              let key = lastCacheKey else { return }
        recLog.info("User cancelled within rejection window — rejecting cache key")
        LLMCache.shared.reject(key: key)
        lastCacheKey = nil
    }

    func reportUserRedo() {
        guard let commitAt = lastCommitAt,
              Date().timeIntervalSince(commitAt) < rejectionWindow,
              let key = lastCacheKey else { return }
        recLog.info("User redid recording within rejection window — rejecting cache key")
        LLMCache.shared.reject(key: key)
        lastCacheKey = nil
    }

    func reportAcceptedSend() {
        // Clear ALL per-utterance state. Otherwise the tap will catch our own
        // synthetic Enter bouncing through (or a later real Enter) and
        // trigger learnFromUserEditIfAny a second time against stale state.
        lastCacheKey = nil
        lastCommitAt = nil
        lastPastedText = nil
        lastProcessedText = nil
        userEditing = false
        restoreClipboardIfNeeded()
    }

    func rejectLastCacheKey() {
        guard let key = lastCacheKey else {
            recLog.info("No last cache key to forget")
            return
        }
        recLog.info("Manual forget — rejecting cache key")
        LLMCache.shared.reject(key: key)
        lastCacheKey = nil
    }

    // MARK: - User-edit learning

    /// Called right before an Enter is sent (auto or manual). If the caller
    /// has already captured the focused text synchronously, pass it in via
    /// `capturedText` — necessary for manual Enter, because by the time the
    /// main-queue block runs the target app has often cleared the field.
    func learnFromUserEditIfAny(capturedText: String? = nil) {
        guard let pasted = lastPastedText else { return }

        let current = capturedText ?? FocusedTextReader.read()
        guard let current = current, !current.isEmpty else {
            recLog.info("AX read failed or empty — cannot learn from edit")
            // Still clear tracking so stale state doesn't leak across utterances.
            lastPastedText = nil
            lastProcessedText = nil
            lastCacheKey = nil
            userEditing = false
            return
        }
        guard current != pasted else {
            lastPastedText = nil
            lastProcessedText = nil
            userEditing = false
            return
        }

        // Sanity check: if the captured text is much shorter than pasted, the
        // user is probably mid-edit (they've deleted a chunk but haven't
        // retyped yet). Better to skip than to learn a half-edit.
        if current.count < max(3, pasted.count / 3) {
            recLog.info("Captured text is much shorter than pasted — treating as mid-edit, skipping learn")
            return
        }

        // Sanity check the other direction: if the user massively expanded
        // the text (e.g. STT gave "Hubery" and they typed a whole sentence),
        // that's a rewrite, not a word-level correction. Learning it would
        // poison VocabDB + LLMCache with a short-fragment → paragraph map.
        if current.count > max(pasted.count * 3, pasted.count + 80) {
            recLog.info("Captured text is much longer than pasted — treating as rewrite, skipping learn")
            lastPastedText = nil
            lastProcessedText = nil
            lastCacheKey = nil
            userEditing = false
            return
        }

        recLog.info("User edited before send: \(pasted, privacy: .public) -> \(current, privacy: .public)")

        // Log the final (edited) text as this utterance's session entry.
        SessionStore.shared.append(
            rawText: lastProcessedText ?? pasted,
            finalText: current,
            appBundleID: ActiveAppContext.frontmostBundleID,
            appDisplayName: ActiveAppContext.frontmostDisplayName,
            wasCancelled: false
        )
        LearningAgent.shared.triggerIfNeeded()

        vocabDB.learnFromDiff(original: pasted, corrected: current, source: "user_edit")

        if let key = lastCacheKey {
            LLMCache.shared.reject(key: key)
        }

        if let processed = lastProcessedText {
            LLMCache.shared.put(
                raw: processed,
                refined: current,
                model: settings.llmModel,
                lang: settings.selectedLanguage
            )
        }

        lastPastedText = nil
        lastProcessedText = nil
        lastCacheKey = nil
        userEditing = false
    }

    // MARK: - Text Injection

    /// Paste `text` into the foreground app. If `preserveClipboard` is true,
    /// the original clipboard contents are saved and will be restored by a
    /// later call to `restoreClipboardIfNeeded()`.
    private var savedClipboard: String?
    private var clipboardWasSaved = false

    private func injectText(_ text: String, preserveClipboard: Bool) {
        injectingCount += 1
        defer {
            // Decrement slightly later to cover the round-trip of our
            // synthetic Cmd+V event coming back through our own tap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.injectingCount = max(0, self.injectingCount - 1)
            }
        }

        let pb = NSPasteboard.general
        if preserveClipboard && !clipboardWasSaved {
            savedClipboard = pb.string(forType: .string)
            clipboardWasSaved = true
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needSwitch = !isASCIICapable(originalSource)

        if needSwitch, let ascii = findASCIICapableSource() {
            TISSelectInputSource(ascii)
            usleep(50_000)
        }

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
    }

    /// Cmd+Z to undo the previous paste, then paste the new text.
    /// Most macOS text fields treat a single paste as one undoable unit.
    private func replaceLastPaste(with newText: String) {
        injectingCount += 1
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.injectingCount = max(0, self.injectingCount - 1)
            }
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        if let d = CGEvent(keyboardEventSource: src, virtualKey: 0x06, keyDown: true) {
            d.flags = .maskCommand; d.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let u = CGEvent(keyboardEventSource: src, virtualKey: 0x06, keyDown: false) {
            u.flags = .maskCommand; u.post(tap: .cgAnnotatedSessionEventTap)
        }
        usleep(80_000)

        injectText(newText, preserveClipboard: false)
        lastPastedText = newText
    }

    private func restoreClipboardIfNeeded() {
        guard clipboardWasSaved else { return }
        let pb = NSPasteboard.general
        let saved = savedClipboard
        clipboardWasSaved = false
        savedClipboard = nil
        pb.clearContents()
        if let s = saved { pb.setString(s, forType: .string) }
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

    // MARK: - Audio Level

    private func handleAudioLevel(_ level: Float) {
        audioLevelProvider.update(rawLevel: level)
        if state.isRecording {
            floatingPanel.updateContent(audioLevel: audioLevelProvider.smoothedLevel)
        }
    }
}
