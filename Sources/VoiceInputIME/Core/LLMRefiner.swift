import Foundation
import os.log

private let llmLog = Logger(subsystem: "com.voiceinput.app", category: "LLMRefiner")

/// Result of a refine pass. `cacheKey` is set when the result went through
/// LLMCache (either hit or freshly stored). Callers use it to report
/// rejections (e.g. user Esc-cancelled the resulting send).
/// `error` is non-nil when the LLM call failed; `text` still holds the
/// unrefined input so paste proceeds normally.
struct RefineResult {
    let text: String
    let cacheKey: String?
    let wasFromCache: Bool
    let error: String?
}

final class LLMRefiner {

    func refine(text: String, context: String = "", settings: AppSettings) async -> RefineResult {
        guard settings.isLLMConfigured else {
            return RefineResult(text: text, cacheKey: nil, wasFromCache: false, error: nil)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RefineResult(text: text, cacheKey: nil, wasFromCache: false, error: nil)
        }

        // Cache hit → zero-latency return, no LLM call.
        if let hit = LLMCache.shared.get(raw: trimmed, model: settings.llmModel, lang: settings.selectedLanguage) {
            llmLog.info("cache hit: \(trimmed, privacy: .private)")
            return RefineResult(text: hit.refinedText, cacheKey: hit.key, wasFromCache: true, error: nil)
        }

        let endpoint = "\(settings.llmBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions"
        guard let url = URL(string: endpoint) else {
            return RefineResult(text: text, cacheKey: nil, wasFromCache: false, error: "Invalid LLM URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(settings.llmAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5.0

        // Feed the user's personal vocabulary (custom names, project names,
        // tech terms, etc.) so the LLM can catch substitutions that STT
        // misheard — e.g. "super" should really be "Hubery" when that name
        // appears frequently in the user's history.
        let userVocab = VocabularyDB.shared.topCorrectedTerms(limit: 50)
        let vocabLine = userVocab.isEmpty
            ? ""
            : "\nThe user's personal vocabulary (names, terms they use often): " +
              userVocab.joined(separator: ", ") +
              "\nIf a token in the input is phonetically close to one of these (even if the letters differ), replace it with the exact form above.\n"

        let systemPrompt = """
        You are a conservative speech recognition error corrector.
        ONLY fix clear, obvious transcription mistakes:
        - Chinese homophone errors (配森→Python, 杰森→JSON)
        - Broken words split/merged incorrectly
        - English technical terms mistakenly converted to Chinese
        - Custom names and proper nouns the user frequently uses
        NEVER rewrite, polish, rephrase, or remove content that appears correct.
        If the input looks correct, return it as-is.
        Return ONLY the corrected text, nothing else.\(vocabLine)
        """

        let body: [String: Any] = [
            "model": settings.llmModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": trimmed],
            ],
            "temperature": 0.3,
            "max_tokens": 500,
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                llmLog.error("LLM HTTP \(code)")
                return RefineResult(text: text, cacheKey: nil, wasFromCache: false, error: "LLM HTTP \(code)")
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
                // Guard against the LLM ignoring its instructions and rewriting
                // the input. Local models (esp. small quantized ones) often
                // expand "test" → "来测试一下剪切板"-style hallucinations even
                // with NEVER-REWRITE prompts. Reject and use raw text instead.
                if let reason = Self.rejectionReason(raw: trimmed, refined: result) {
                    llmLog.warning("LLM rewrite rejected: \(reason, privacy: .public)")
                    return RefineResult(text: text, cacheKey: nil, wasFromCache: false, error: "LLM rewrite rejected")
                }
                llmLog.info("\(trimmed, privacy: .private) -> \(result, privacy: .private)")
                let key = LLMCache.shared.put(
                    raw: trimmed,
                    refined: result,
                    model: settings.llmModel,
                    lang: settings.selectedLanguage
                )
                return RefineResult(text: result, cacheKey: key, wasFromCache: false, error: nil)
            }
            llmLog.error("LLM response parse failed")
            return RefineResult(text: text, cacheKey: nil, wasFromCache: false, error: "LLM response parse failed")
        } catch {
            llmLog.error("Failed: \(error, privacy: .public)")
            return RefineResult(text: text, cacheKey: nil, wasFromCache: false, error: error.localizedDescription)
        }
    }

    /// Detect LLM hallucinations / rewrites that should not replace the raw
    /// transcription. Returns a short reason string when the refined text
    /// looks suspicious, nil when it's a legitimate correction.
    /// Mirror of (and stricter than) `LLMCache.poisonReason`.
    static func rejectionReason(raw: String, refined: String) -> String? {
        if refined.contains("\n") { return "contains newline" }
        if refined.count > 200 { return "refined too long (\(refined.count))" }
        // Length expansion guard: a real correction is roughly the same size.
        // Anything more than 3x raw + 6 chars of slack is almost certainly a
        // rewrite, not a homophone fix.
        if refined.count > raw.count * 3 + 6 { return "refined > 3x raw" }
        // Language-flip guard: ASCII-heavy input shouldn't become CJK-heavy
        // output (or vice versa) — that's a translation/expansion, not a fix.
        let rawASCIIRatio = Self.asciiRatio(raw)
        let refASCIIRatio = Self.asciiRatio(refined)
        if rawASCIIRatio > 0.7 && refASCIIRatio < 0.4 { return "ASCII input → CJK output" }
        if rawASCIIRatio < 0.3 && refASCIIRatio > 0.7 { return "CJK input → ASCII output" }
        return nil
    }

    private static func asciiRatio(_ s: String) -> Double {
        let nonSpace = s.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !nonSpace.isEmpty else { return 1 }
        let ascii = nonSpace.filter { $0.isASCII }
        return Double(ascii.count) / Double(nonSpace.count)
    }
}
