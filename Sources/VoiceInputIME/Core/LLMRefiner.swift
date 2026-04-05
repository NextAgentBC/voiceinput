import Foundation

final class LLMRefiner {
    private let correctionEndpoint = "https://asr.borui.ca/v1/asr/correct"
    private let token = "RZpLK0h7Fs9McBfMNFfjuLFK5nuC5gVYbxDptbmtbzc"

    func refine(text: String, context: String = "", settings: AppSettings) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        var req = URLRequest(url: URL(string: correctionEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5.0

        var body: [String: Any] = ["text": trimmed]
        if !context.isEmpty { body["context"] = String(context.suffix(300)) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return text }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let corrected = json["corrected"] as? String,
               !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSLog("[LLMRefiner] %@ → %@", trimmed, corrected)
                return corrected
            }
        } catch {
            NSLog("[LLMRefiner] Failed: %@", "\(error)")
        }
        return text
    }

    /// Test the LLM connection with a simple request
    func testConnection(baseURL: String, apiKey: String, model: String) async -> (Bool, String) {
        let endpoint = "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions"

        guard let url = URL(string: endpoint) else {
            return (false, "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10.0

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "Say OK"],
            ],
            "max_tokens": 10,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return (false, "JSON encoding error")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Invalid response")
            }

            if httpResponse.statusCode == 200 {
                return (true, "Connection successful!")
            } else {
                return (false, "HTTP \(httpResponse.statusCode)")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
