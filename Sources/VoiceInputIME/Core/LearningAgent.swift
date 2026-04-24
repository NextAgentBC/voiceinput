import Foundation
import os.log

private let agentLog = Logger(subsystem: "com.voiceinput.app", category: "LearningAgent")

/// Background learning agent. Runs L2 passes: asks the LLM to mine
/// recurring STT errors + user vocabulary from recent transcript entries,
/// then writes the results into LLMCache + VocabDB so next utterance gets
/// the benefit instantly.
///
/// L1 (realtime) already happens in the RecordingSession pipeline.
/// L3 (reflection) is not yet implemented — low-confidence entries from L2
/// are simply tagged and the feedback-rejection loop (`LLMCache.reject`)
/// prunes bad entries organically.
final class LearningAgent {
    static let shared = LearningAgent()

    /// Run L2 after this many new entries since the last L2 run.
    static let entryTriggerCount = 20
    /// Also run L2 if this much wall time has passed since the last run.
    static let timeTriggerInterval: TimeInterval = 24 * 3600
    /// How many recent entries to include in each L2 pass.
    static let inputBatchSize = 80

    private var isRunning = false
    private let lock = NSLock()

    private init() {}

    // MARK: - Trigger

    /// Non-blocking check. Called after every successful commit by the
    /// recording session. Launches an L2 run if thresholds are met.
    func triggerIfNeeded() {
        guard AppSettings.shared.agentAutoLearnEnabled else { return }
        guard AppSettings.shared.isLLMConfigured else { return }

        let total = SessionStore.shared.entryCount()
        let lastRunAt = SessionStore.shared.lastAgentRunAt(tier: "L2")
        let lastRunEntryCount = UserDefaults.standard.integer(forKey: "lastL2EntryCountSeen")
        let delta = total - lastRunEntryCount

        let enoughEntries = delta >= LearningAgent.entryTriggerCount
        let enoughTime = lastRunAt.map { Date().timeIntervalSince($0) >= LearningAgent.timeTriggerInterval } ?? true

        guard enoughEntries || enoughTime else { return }

        // Throttle: never more than once every 10 minutes regardless of triggers.
        if let last = lastRunAt, Date().timeIntervalSince(last) < 600 { return }

        Task.detached { [weak self] in
            await self?.runL2(reason: enoughEntries ? "entry-count" : "time-trigger")
        }
    }

    /// Manual "Run Now" from the menu.
    func runManualL2() {
        Task.detached { [weak self] in
            await self?.runL2(reason: "manual")
        }
    }

    // MARK: - L2

    func runL2(reason: String) async {
        lock.lock()
        if isRunning { lock.unlock(); return }
        isRunning = true
        lock.unlock()
        defer {
            lock.lock()
            isRunning = false
            lock.unlock()
        }

        agentLog.info("L2 start (reason=\(reason, privacy: .public))")

        let settings = AppSettings.shared
        guard settings.isLLMConfigured else {
            agentLog.warning("LLM not configured, skipping L2")
            return
        }

        let entries = SessionStore.shared.recentEntries(limit: LearningAgent.inputBatchSize)
        guard entries.count >= 5 else {
            agentLog.info("Not enough entries for L2 (\(entries.count))")
            return
        }

        // Only rows where final differs from raw (or that were cancelled) are
        // genuinely informative — a perfect STT output teaches nothing.
        let informative = entries.filter { $0.finalText != $0.rawText || $0.wasCancelled }
        guard informative.count >= 3 else {
            agentLog.info("Not enough informative entries (\(informative.count))")
            return
        }

        let prompt = buildPrompt(entries: informative)
        let rawResponse = await callLLM(prompt: prompt, settings: settings)
        guard let json = parseJSON(rawResponse) else {
            agentLog.error("L2 LLM response not parseable")
            recordRun(tier: "L2", input: informative.count, corrections: 0, vocab: 0, summary: "Parse failed")
            return
        }

        var correctionsAdded = 0
        var vocabAdded = 0

        if let corrections = json["corrections"] as? [[String: Any]] {
            for c in corrections {
                guard let raw = c["raw"] as? String,
                      let corrected = c["corrected"] as? String,
                      raw != corrected,
                      let conf = (c["confidence"] as? Double) ?? (c["confidence"] as? NSNumber)?.doubleValue,
                      conf >= 0.85 else { continue }
                LLMCache.shared.put(
                    raw: raw,
                    refined: corrected,
                    model: settings.llmModel,
                    lang: settings.selectedLanguage
                )
                correctionsAdded += 1
            }
        }

        if let vocab = json["user_vocabulary"] as? [[String: Any]] {
            for v in vocab {
                guard let term = v["term"] as? String, !term.isEmpty else { continue }
                let aliases = (v["aliases"] as? [String]) ?? []
                for alias in aliases where alias != term {
                    VocabularyDB.shared.learn(original: alias, corrected: term, source: "agent_l2", confidence: 0.8)
                    vocabAdded += 1
                }
            }
        }

        let summary = (json["summary"] as? String) ?? "Added \(correctionsAdded) corrections, \(vocabAdded) vocab"
        recordRun(tier: "L2", input: informative.count, corrections: correctionsAdded, vocab: vocabAdded, summary: summary)
        UserDefaults.standard.set(SessionStore.shared.entryCount(), forKey: "lastL2EntryCountSeen")
        agentLog.info("L2 done: \(correctionsAdded, privacy: .public) corrections, \(vocabAdded, privacy: .public) vocab")
    }

    // MARK: - Prompt

    private func buildPrompt(entries: [TranscriptEntry]) -> String {
        var rows: [[String: Any]] = []
        for e in entries {
            var row: [String: Any] = [
                "raw": e.rawText,
                "final": e.finalText,
            ]
            if e.wasCancelled { row["cancelled"] = true }
            rows.append(row)
        }
        let jsonData = (try? JSONSerialization.data(withJSONObject: rows, options: [])) ?? Data()
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? "[]"

        return """
        You are a speech recognition log analyst. Given recent transcription \
        records where "raw" is what STT produced and "final" is what the user \
        actually sent (possibly after manual editing), identify:

        1. Recurring STT mistakes that should be auto-corrected. Only include \
           mappings that appear consistently and have high confidence (≥0.85).
        2. User-specific vocabulary (technical terms, product names, people \
           names) and any aliases STT tends to produce for them.

        Input entries (JSON):
        \(jsonStr)

        Respond with ONLY valid JSON in this exact shape:
        {
          "corrections": [
            {"raw": "...", "corrected": "...", "confidence": 0.0, "reason": "..."}
          ],
          "user_vocabulary": [
            {"term": "...", "aliases": ["..."], "context": "..."}
          ],
          "summary": "one short sentence"
        }

        Rules:
        - "raw" must match a string actually seen in the input.
        - Do NOT invent corrections not supported by the data.
        - Confidence reflects how consistent the pattern is across entries.
        - If there are no strong patterns, return empty arrays.
        """
    }

    // MARK: - LLM call

    private func callLLM(prompt: String, settings: AppSettings) async -> String? {
        let endpoint = "\(settings.llmBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions"
        guard let url = URL(string: endpoint) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(settings.llmAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "model": settings.llmModel,
            "messages": [
                ["role": "user", "content": prompt],
            ],
            "temperature": 0.2,
            "max_tokens": 2000,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                agentLog.error("L2 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        } catch {
            agentLog.error("L2 request failed: \(error, privacy: .public)")
        }
        return nil
    }

    private func parseJSON(_ str: String?) -> [String: Any]? {
        guard let str = str else { return nil }
        // LLM sometimes wraps JSON in markdown code fences.
        var cleaned = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Recording runs

    private func recordRun(tier: String, input: Int, corrections: Int, vocab: Int, summary: String) {
        let run = AgentRun(
            id: UUID().uuidString,
            tier: tier,
            runAt: Date(),
            inputCount: input,
            correctionsAdded: corrections,
            vocabAdded: vocab,
            summary: summary,
            tokenCost: 0
        )
        SessionStore.shared.insertAgentRun(run)
    }
}
