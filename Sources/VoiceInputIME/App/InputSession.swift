import Cocoa
import Carbon
import os.log

private let recLog = Logger(subsystem: "com.voiceinput.app", category: "Recording")

// MARK: - Utterance (B3)

/// All per-utterance state, bundled so every reset site is a single assignment.
private struct Utterance {
    var pastedText: String?
    var processedText: String?
    var cacheKey: String?
    var commitAt: Date?
    var userEditing: Bool = false
    var partialTranscript: String = ""
}

/// Singleton recording session with pluggable STT engine.
@MainActor  // B2: all mutations on main actor
final class RecordingSession {
    @MainActor static let shared = RecordingSession()

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

    // A1: engine captured once per recording, cleared at every terminal path.
    private var activeEngine: STTEngine?

    // MARK: - Atomic flags for off-main reads (B2)

    // The CGEventTap callback reads these two flags from a non-main thread.
    // OSAllocatedUnfairLock is safe to read/write from any thread and
    // available from macOS 13 (deployment target is 14).
    private let injectingFlag = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let refiningFlag  = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Latest visible transcript snapshot (partial during recording, final
    /// after commit). Read off-main by the CGEventTap to handle the Cmd+C
    /// "copy from floating panel" shortcut. Empty string = nothing to copy.
    private let copyableTranscript = OSAllocatedUnfairLock<String>(initialState: "")

    /// Nonisolated readers — safe to call from the CGEventTap callback thread.
    nonisolated var isInjectingNonisolated: Bool {
        injectingFlag.withLock { $0 > 0 }
    }
    nonisolated var isRefiningNonisolated: Bool {
        refiningFlag.withLock { $0 }
    }
    /// Returns the current copyable transcript (or nil if empty). Called from
    /// the global event tap to decide whether to intercept Cmd+C.
    nonisolated var copyableTranscriptNonisolated: String? {
        let s = copyableTranscript.withLock { $0 }
        return s.isEmpty ? nil : s
    }

    // MARK: - Components
    private let audioLevelProvider = AudioLevelProvider()
    private let textPostProcessor = TextPostProcessor()
    private let llmRefiner = LLMRefiner()
    private let vocabDB = VocabularyDB.shared
    private let floatingPanel = FloatingPanel()

    private var settings: AppSettings { AppSettings.shared }

    // MARK: - State
    private var state: RecognitionState = .idle {
        didSet {
            let isRef = state.isRefining
            refiningFlag.withLock { $0 = isRef }
            if oldValue != state {
                NotificationCenter.default.post(name: .voiceInputStateChanged, object: nil)
            }
        }
    }
    private var activeTask: Task<Void, Never>?

    var isRefining: Bool { state.isRefining }
    var isRecording: Bool { state.isRecording }

    /// Counter-based "we are injecting" flag. Using a counter (incremented
    /// on each inject, decremented after a short cooldown) avoids the race
    /// where two overlapping paste-backs cause the earlier block's deferred
    /// setter to clear the flag while a later paste is still in flight.
    private var injectingCount: Int = 0 {
        didSet {
            let count = injectingCount
            injectingFlag.withLock { $0 = count }
        }
    }
    var isInjecting: Bool { injectingCount > 0 }

    private let rejectionWindow: TimeInterval = 8

    /// Recordings shorter than this are treated as accidental Fn taps —
    /// silently dismissed instead of showing "Didn't catch that". Apple
    /// Speech and most cloud APIs cannot reliably transcribe sub-half-second
    /// utterances, especially in CJK languages.
    private let minRecordingDuration: TimeInterval = 0.4

    /// Wall-clock timestamp when the current recording started, used to
    /// distinguish accidental taps from real (failed) utterances.
    private var recordingStartedAt: Date?

    // MARK: - Per-utterance state (B3)
    private var utterance = Utterance()

    private init() {}

    // MARK: - Active-engine cleanup (A1)

    private func clearActiveEngine() {
        activeEngine = nil
        recordingStartedAt = nil
        copyableTranscript.withLock { $0 = "" }
    }

    // MARK: - Public API

    func startRecording() {
        guard state.isIdle else { return }
        reportUserRedo()
        PreSendController.shared.cancel()
        // Fresh utterance — any leftover state from a cancelled/interrupted
        // previous pipeline must not leak into this one.
        utterance = Utterance()
        activeTask = nil
        recLog.info("START (engine: \(self.settings.sttEngineType.rawValue, privacy: .public))")

        state = .recording
        recordingStartedAt = Date()
        floatingPanel.updateContent(audioLevel: 0)
        floatingPanel.showWithAnimation()

        // A1: capture the engine once so mid-recording engine-type changes
        // don't route stopRecording to a different instance.
        let engine = currentEngine
        activeEngine = engine
        engine.onAudioLevel = { [weak self] level in
            self?.handleAudioLevel(level)
        }
        engine.onPartialTranscript = { [weak self] text in
            self?.handlePartialTranscript(text)
        }
        do {
            try engine.startRecording(language: settings.selectedLanguage)
        } catch {
            recLog.error("Failed to start: \(error, privacy: .public)")
            state = .idle
            clearActiveEngine()
            floatingPanel.hideWithAnimation()
        }
    }

    func stopRecording() {
        guard state.isRecording else { return }
        recLog.info("STOP")

        state = .refining
        utterance.partialTranscript = ""
        floatingPanel.updateContent(audioLevel: 0, isRefining: true, partialText: nil)

        // A1: read captured engine, not currentEngine.
        let engine = activeEngine

        activeTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runPipeline(engine: engine)
            // Safety net: whatever path the pipeline took, don't leave the
            // UI stuck in "refining" state.
            await MainActor.run {
                if self.state.isRefining {
                    self.state = .idle
                    self.clearActiveEngine()
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
    private func runPipeline(engine: STTEngine?) async {
        let sttResult = await engine?.stopRecording(context: "")
        guard !Task.isCancelled, self.state.isRefining else { return }

        let rawText: String
        switch sttResult {
        case .success(let text):
            rawText = text
        case .failure(let err):
            recLog.error("STT error: \(err.errorDescription ?? err.userMessage, privacy: .public)")
            await MainActor.run {
                self.utterance = Utterance()
                self.state = .idle
                self.refiningFlag.withLock { $0 = false }
                self.floatingPanel.showError(err.userMessage, duration: 3.0)
                self.activeEngine = nil
            }
            NotificationCenter.default.post(
                name: .voiceInputSTTError,
                object: nil,
                userInfo: ["message": err.userMessage]
            )
            return
        case nil:
            rawText = ""
        }

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Distinguish "user spoke but STT failed" from "user accidentally
            // tapped Fn" — only show the toast for the former.
            let elapsed = self.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let wasIntentional = elapsed >= self.minRecordingDuration
            await MainActor.run {
                // Transition to idle before showing the toast so the safety net
                // in stopRecording doesn't interfere with the toast display.
                self.state = .idle
                self.restoreClipboardIfNeeded()
                self.utterance = Utterance()
                self.clearActiveEngine()
                self.recordingStartedAt = nil
                if wasIntentional {
                    self.floatingPanel.showToast("Didn't catch that", duration: 1.2)
                } else {
                    self.floatingPanel.hideWithAnimation()
                }
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
            // Belt-and-suspenders: a poisoned entry could still exist in
            // databases created before we tightened the write-side guards.
            // Detect and reject such entries instead of pasting them.
            if hit.refinedText.contains("\n") || hit.refinedText.count > 200 {
                recLog.warning("Poisoned cache entry detected — rejecting and falling through to LLM")
                LLMCache.shared.reject(key: hit.key)
            } else {
                recLog.info("cache hit — paste refined directly")
                await MainActor.run {
                    self.injectText(hit.refinedText, preserveClipboard: true)
                    self.utterance.pastedText = hit.refinedText
                    self.utterance.processedText = processed
                    self.utterance.cacheKey = hit.key
                    self.finalizeCommit(text: hit.refinedText, bundleID: bundleID, profile: profile)
                }
                return
            }
        }

        // Cache miss: paste processed immediately, then run LLM purely to
        // populate the cache. We do NOT overwrite the pasted text with the
        // LLM result — the user asked us not to flash/replace.
        await MainActor.run {
            self.injectText(processed, preserveClipboard: true)
            self.utterance.pastedText = processed
            self.utterance.processedText = processed
            self.utterance.cacheKey = nil
        }

        let result = await self.llmRefiner.refine(text: processed, context: "", settings: self.settings)
        guard !Task.isCancelled, self.state.isRefining else { return }

        if let llmErr = result.error {
            await MainActor.run {
                self.floatingPanel.showError("Refine offline — using raw text", duration: 1.5)
            }
            recLog.warning("LLM error: \(llmErr, privacy: .public)")
        }

        if result.text != processed {
            self.vocabDB.learnFromDiff(original: rawText, corrected: result.text, source: "ai")
        }

        if self.utterance.userEditing {
            recLog.info("User edited during LLM — skipping auto-send")
            await MainActor.run {
                self.state = .idle
                self.floatingPanel.hideWithAnimation()
                self.utterance.commitAt = Date()
                // If LLM produced something, cache it keyed by processed for future.
                if result.cacheKey != nil {
                    self.utterance.cacheKey = result.cacheKey
                }
                self.clearActiveEngine()
                // utterance.pastedText stays — user's pending Enter will read AX and learn.
            }
            return
        }

        await MainActor.run {
            self.finalizeCommit(text: processed, bundleID: bundleID, profile: profile)
        }
    }

    /// Called the moment the user presses any key or clicks mouse that
    /// implies they are editing the pasted text. We stop trying to overwrite
    /// it and stop the auto-send, but preserve `utterance.pastedText` so that
    /// whenever they finally press Enter we can learn their final version.
    func userStartedEditing() {
        guard utterance.pastedText != nil, !utterance.userEditing else { return }
        recLog.info("User started editing pasted text")
        utterance.userEditing = true
        activeTask?.cancel()
        PreSendController.shared.cancel()
        // A cancelled Task may bail out before its own cleanup runs, so the
        // floating panel could otherwise spin forever. Force the state back
        // to idle here.
        if state.isRefining {
            state = .idle
            floatingPanel.hideWithAnimation()
        }
        utterance.commitAt = Date()
    }

    func cancelRecording() {
        recLog.info("CANCEL")
        activeTask?.cancel()
        activeTask = nil
        // A1: cancel using the captured engine, not currentEngine.
        let engineToStop = activeEngine
        Task { _ = await engineToStop?.stopRecording(context: "") as Any }
        clearActiveEngine()
        state = .idle
        floatingPanel.hideWithAnimation()
        // Paste (if it happened) stays visible. User decides what to do.
        // We clear ALL utterance-scoped state so it doesn't leak into the next one.
        utterance = Utterance()
        restoreClipboardIfNeeded()
    }

    // MARK: - Commit finalization

    private func finalizeCommit(text: String, bundleID: String?, profile: AppProfile?) {
        state = .idle
        floatingPanel.hideWithAnimation()
        utterance.commitAt = Date()
        clearActiveEngine()
        recLog.info("Commit: \(text, privacy: .private)")

        // Log this utterance into the session store.
        SessionStore.shared.append(
            rawText: utterance.processedText ?? text,
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
            // CGEvent Cmd+V is posted asynchronously — the target app hasn't
            // read the pasteboard yet at this point. If we restore the saved
            // clipboard synchronously the user sees their OLD clipboard land
            // in the field instead of the dictation. Delay the restore so
            // Cmd+V has a chance to be processed first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.restoreClipboardIfNeeded()
            }
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
        guard let commitAt = utterance.commitAt,
              Date().timeIntervalSince(commitAt) < rejectionWindow,
              let key = utterance.cacheKey else { return }
        recLog.info("User cancelled within rejection window — rejecting cache key")
        LLMCache.shared.reject(key: key)
        utterance.cacheKey = nil
    }

    func reportUserRedo() {
        guard let commitAt = utterance.commitAt,
              Date().timeIntervalSince(commitAt) < rejectionWindow,
              let key = utterance.cacheKey else { return }
        recLog.info("User redid recording within rejection window — rejecting cache key")
        LLMCache.shared.reject(key: key)
        utterance.cacheKey = nil
    }

    func reportAcceptedSend() {
        // Clear ALL per-utterance state. Otherwise the tap will catch our own
        // synthetic Enter bouncing through (or a later real Enter) and
        // trigger learnFromUserEditIfAny a second time against stale state.
        utterance = Utterance()
        restoreClipboardIfNeeded()
    }

    func rejectLastCacheKey() {
        guard let key = utterance.cacheKey else {
            recLog.info("No last cache key to forget")
            return
        }
        recLog.info("Manual forget — rejecting cache key")
        LLMCache.shared.reject(key: key)
        utterance.cacheKey = nil
    }

    // MARK: - User-edit learning

    /// Called right before an Enter is sent (auto or manual). If the caller
    /// has already captured the focused text synchronously, pass it in via
    /// `capturedText` — necessary for manual Enter, because by the time the
    /// main-queue block runs the target app has often cleared the field.
    func learnFromUserEditIfAny(capturedText: String? = nil) {
        guard let pasted = utterance.pastedText else { return }

        let current = capturedText ?? FocusedTextReader.read()
        guard let current = current, !current.isEmpty else {
            recLog.info("AX read failed or empty — cannot learn from edit")
            // Still clear tracking so stale state doesn't leak across utterances.
            utterance = Utterance()
            return
        }
        guard current != pasted else {
            utterance.pastedText = nil
            utterance.processedText = nil
            utterance.userEditing = false
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
        if current.count > max(pasted.count * 3, pasted.count + 40) {
            recLog.info("Captured text is much longer than pasted — treating as rewrite, skipping learn")
            utterance = Utterance()
            return
        }

        // Multi-line capture, absurdly long capture, or self-replication
        // (pasted text appearing more than once inside captured) — these are
        // the exact shapes that produced the historical poisoned entries.
        // Reject before learn to keep the cache clean.
        if current.contains("\n")
            || current.count > 200
            || containsRepetition(of: pasted, in: current) {
            recLog.warning("Suspicious edit shape — skipping learn (newline/oversize/repetition)")
            utterance = Utterance()
            return
        }

        recLog.info("User edited before send: \(pasted, privacy: .private) -> \(current, privacy: .private)")

        // Log the final (edited) text as this utterance's session entry.
        SessionStore.shared.append(
            rawText: utterance.processedText ?? pasted,
            finalText: current,
            appBundleID: ActiveAppContext.frontmostBundleID,
            appDisplayName: ActiveAppContext.frontmostDisplayName,
            wasCancelled: false
        )
        LearningAgent.shared.triggerIfNeeded()

        vocabDB.learnFromDiff(original: pasted, corrected: current, source: "user_edit")

        if let key = utterance.cacheKey {
            LLMCache.shared.reject(key: key)
        }

        if let processed = utterance.processedText {
            LLMCache.shared.put(
                raw: processed,
                refined: current,
                model: settings.llmModel,
                lang: settings.selectedLanguage
            )
        }

        utterance = Utterance()
    }

    /// True iff `needle` appears two or more times inside `haystack`.
    /// Used to catch self-replication when a user-edited capture contains
    /// multiple copies of what we previously pasted — the signature of the
    /// poisoned-cache feedback loop we are guarding against.
    private func containsRepetition(of needle: String, in haystack: String) -> Bool {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        var search = haystack[...]
        var count = 0
        while let r = search.range(of: trimmed, options: .caseInsensitive) {
            count += 1
            if count >= 2 { return true }
            search = search[r.upperBound...]
        }
        return false
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

        // Clipboard preservation removed: previously we saved the user's
        // existing clipboard, wrote our dictation, posted Cmd+V, then later
        // restored the saved value. That clobbered any text the user copied
        // (Cmd+C) in the interval between paste and restore — breaking
        // normal copy-paste in unrelated apps. The dictated text simply
        // stays on the clipboard now; user can re-paste it if they want.
        // `preserveClipboard` parameter is ignored.
        _ = preserveClipboard

        let pb = NSPasteboard.general
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
        utterance.pastedText = newText
    }

    /// No-op now — preserve-clipboard feature dropped. Kept as a stub so the
    /// existing call sites compile unchanged. Removable in a follow-up cleanup.
    private func restoreClipboardIfNeeded() {
        // Intentionally empty.
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
            floatingPanel.updateContent(
                audioLevel: audioLevelProvider.smoothedLevel,
                partialText: utterance.partialTranscript.isEmpty ? nil : utterance.partialTranscript
            )
        }
    }

    private func handlePartialTranscript(_ text: String) {
        guard state.isRecording else { return }
        utterance.partialTranscript = text
        copyableTranscript.withLock { $0 = text }
        floatingPanel.updateContent(
            audioLevel: audioLevelProvider.smoothedLevel,
            partialText: text.isEmpty ? nil : text
        )
    }

    /// Called from the global event tap when Cmd+C is intercepted while a
    /// transcript is visible. Writes the current text to the pasteboard.
    func copyVisibleTranscript() {
        let text = copyableTranscript.withLock { $0 }
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        floatingPanel.showToast("Copied", duration: 1.0)
        recLog.info("Cmd+C copy: \(text.count) chars")
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let voiceInputStateChanged = Notification.Name("VoiceInput.StateChanged")
    static let voiceInputSTTError     = Notification.Name("VoiceInput.STTError")
}
