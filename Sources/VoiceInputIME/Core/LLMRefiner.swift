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

        // Cache hit → zero-latency return, no LLM call. Polish mode skips
        // the cache: outputs include newlines/bullets (poisonReason rejects
        // those) and the same raw can yield different valid polish each time.
        if !settings.llmPolishMode,
           let hit = LLMCache.shared.get(raw: trimmed, model: settings.llmModel, lang: settings.selectedLanguage) {
            llmLog.info("cache hit: \(trimmed, privacy: .private)")
            return RefineResult(text: hit.refinedText, cacheKey: hit.key, wasFromCache: true, error: nil)
        }

        let endpoint = "\(settings.llmBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions"
        guard let url = URL(string: endpoint) else {
            return RefineResult(text: text, cacheKey: nil, wasFromCache: false, error: "Invalid LLM URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !settings.llmAPIKey.isEmpty {
            req.setValue("Bearer \(settings.llmAPIKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Polish mode generates more tokens — needs more time, especially on
        // local llama.cpp servers (~50 tok/s for the configured model).
        req.timeoutInterval = settings.llmPolishMode ? 30.0 : 5.0

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

        let conservativePrompt = """
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

        let polishPrompt = """
        You are a transcription editor. Take the raw STT output and produce a clean, well-structured version of what the user said.

        WHAT TO DO:
        - Fix recognition errors: Chinese homophones (配森→Python, 杰森→JSON), broken words, tech terms wrongly localized.
        - Add paragraph breaks at natural sentence/topic boundaries when the input is long.
        - When the user is listing items or steps, format them as a Markdown bullet list (`- ` lines) or numbered list as appropriate.
        - Add light punctuation cleanup (commas, periods) where the speaker clearly paused.

        WHAT NOT TO DO:
        - Don't paraphrase or invent content the speaker didn't say.
        - Don't add a preamble, summary, or commentary — only the polished text.
        - Don't translate. Keep the original language(s) of the input.
        - Don't wrap output in code fences.
        - Don't add headings unless the speaker explicitly named sections.

        Return ONLY the polished text.\(vocabLine)
        """

        let systemPrompt = settings.llmPolishMode ? polishPrompt : conservativePrompt

        let body: [String: Any] = [
            "model": settings.llmModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": trimmed],
            ],
            "temperature": settings.llmPolishMode ? 0.4 : 0.3,
            "max_tokens": settings.llmPolishMode ? 1500 : 500,
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
                if let reason = Self.rejectionReason(raw: trimmed, refined: result, polish: settings.llmPolishMode) {
                    llmLog.warning("LLM rewrite rejected: \(reason, privacy: .public)")
                    return RefineResult(text: text, cacheKey: nil, wasFromCache: false, error: "LLM rewrite rejected")
                }
                llmLog.info("\(trimmed, privacy: .private) -> \(result, privacy: .private)")
                // Skip caching in polish mode (newlines / variable output).
                let key: String? = settings.llmPolishMode ? nil : LLMCache.shared.put(
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
    ///
    /// Two thresholds:
    ///   - `polish=false` (default): conservative; refusals catch any rewrite.
    ///   - `polish=true`: allow paragraph breaks, bullet lists, longer output;
    ///     still reject runaway hallucinations.
    static func rejectionReason(raw: String, refined: String, polish: Bool = false) -> String? {
        // Hard runaway cap (always enforced): no model should ever produce
        // wildly more output than the user spoke.
        let maxLen = polish ? 4000 : 200
        let maxRatio = polish ? 6 : 3
        let lenSlack = polish ? 200 : 6

        if !polish && refined.contains("\n") { return "contains newline (conservative mode)" }
        if refined.count > maxLen { return "refined too long (\(refined.count))" }
        if refined.count > raw.count * maxRatio + lenSlack { return "refined > \(maxRatio)x raw" }

        if !polish {
            // Language-flip only enforced in conservative mode. In polish mode
            // structuring may add bullet markers (- / 1.) that change ratios.
            let rawASCIIRatio = Self.asciiRatio(raw)
            let refASCIIRatio = Self.asciiRatio(refined)
            if rawASCIIRatio > 0.7 && refASCIIRatio < 0.4 { return "ASCII input → CJK output" }
            if rawASCIIRatio < 0.3 && refASCIIRatio > 0.7 { return "CJK input → ASCII output" }
        }
        return nil
    }

    private static func asciiRatio(_ s: String) -> Double {
        let nonSpace = s.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !nonSpace.isEmpty else { return 1 }
        let ascii = nonSpace.filter { $0.isASCII }
        return Double(ascii.count) / Double(nonSpace.count)
    }
}
