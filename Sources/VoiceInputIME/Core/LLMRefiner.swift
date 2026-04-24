import Foundation
import os.log

private let llmLog = Logger(subsystem: "com.voiceinput.app", category: "LLMRefiner")

/// Result of a refine pass. `cacheKey` is set when the result went through
/// LLMCache (either hit or freshly stored). Callers use it to report
/// rejections (e.g. user Esc-cancelled the resulting send).
struct RefineResult {
    let text: String
    let cacheKey: String?
    let wasFromCache: Bool
}

final class LLMRefiner {

    func refine(text: String, context: String = "", settings: AppSettings) async -> RefineResult {
        guard settings.isLLMConfigured else {
            return RefineResult(text: text, cacheKey: nil, wasFromCache: false)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RefineResult(text: text, cacheKey: nil, wasFromCache: false)
        }

        // Cache hit → zero-latency return, no LLM call.
        if let hit = LLMCache.shared.get(raw: trimmed, model: settings.llmModel, lang: settings.selectedLanguage) {
            llmLog.info("cache hit: \(trimmed, privacy: .public)")
            return RefineResult(text: hit.refinedText, cacheKey: hit.key, wasFromCache: true)
        }

        let endpoint = "\(settings.llmBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions"
        guard let url = URL(string: endpoint) else {
            return RefineResult(text: text, cacheKey: nil, wasFromCache: false)
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
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return RefineResult(text: text, cacheKey: nil, wasFromCache: false)
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
                llmLog.info("\(trimmed, privacy: .public) -> \(result, privacy: .public)")
                let key = LLMCache.shared.put(
                    raw: trimmed,
                    refined: result,
                    model: settings.llmModel,
                    lang: settings.selectedLanguage
                )
                return RefineResult(text: result, cacheKey: key, wasFromCache: false)
            }
        } catch {
            llmLog.error("Failed: \(error, privacy: .public)")
        }
        return RefineResult(text: text, cacheKey: nil, wasFromCache: false)
    }
}
