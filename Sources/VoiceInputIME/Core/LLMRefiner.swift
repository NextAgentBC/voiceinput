import Foundation

final class LLMRefiner {

    func refine(text: String, context: String = "", settings: AppSettings) async -> String {
        guard settings.isLLMConfigured else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let endpoint = "\(settings.llmBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions"
        guard let url = URL(string: endpoint) else { return text }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(settings.llmAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10.0

        let systemPrompt = """
        You are a conservative speech recognition error corrector.
        ONLY fix clear, obvious transcription mistakes:
        - Chinese homophone errors (配森→Python, 杰森→JSON)
        - Broken words split/merged incorrectly
        - English technical terms mistakenly converted to Chinese
        NEVER rewrite, polish, rephrase, or remove content that appears correct.
        If the input looks correct, return it as-is.
        Return ONLY the corrected text, nothing else.
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
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return text }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[LLMRefiner] %@ -> %@", trimmed, result)
                return result
            }
        } catch {
            NSLog("[LLMRefiner] Failed: %@", "\(error)")
        }
        return text
    }
}
