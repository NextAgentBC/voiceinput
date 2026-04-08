import Foundation

// MARK: - Models

struct MeetingUtterance {
    let speaker: String
    let text: String
    let timestamp: String?
}

struct MeetingTranscript {
    let utterances: [MeetingUtterance]
    let summary: String?
    let actionItems: [String]?

    func formatForPaste() -> String {
        var lines = utterances.map { u in
            let ts = u.timestamp.map { "[\($0)] " } ?? ""
            return "\(ts)\(u.speaker): \(u.text)"
        }
        if let summary = summary, !summary.isEmpty {
            lines.append("\n---\n摘要: \(summary)")
        }
        if let items = actionItems, !items.isEmpty {
            lines.append("\n待办:\n" + items.map { "- \($0)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Client

/// HTTP client for the meeting transcription server (Tailscale direct).
final class MeetingClient {

    // MARK: - /asr — fast speech-to-text only (no diarization, no summary)

    /// POST /asr — fast transcription for real-time segments.
    /// Returns plain text.
    static func asr(audioData: Data, language: String) async -> String? {
        guard let url = makeURL("/asr") else { return nil }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n")
        append("--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[MeetingClient] ASR: \"%@\"", trimmed)
                return trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            NSLog("[MeetingClient] ASR error: %@", "\(error)")
        }
        return nil
    }

    // MARK: - /transcribe/merge — ASR + diarization + alignment (no summary)

    /// POST /transcribe/merge — transcription with speaker labels.
    static func transcribeMerge(audioData: Data, language: String) async -> String? {
        let settings = AppSettings.shared
        guard let url = makeURL("/transcribe/merge") else { return nil }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n")
        if settings.meetingNumSpeakers > 0 {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"num_speakers\"\r\n\r\n\(settings.meetingNumSpeakers)\r\n")
        }
        append("--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let utterances = json["utterances"] as? [[String: Any]], !utterances.isEmpty {
                let lines = utterances.compactMap { u -> String? in
                    guard let speaker = u["speaker"] as? String,
                          let text = u["text"] as? String else { return nil }
                    return "\(speaker): \(text)"
                }
                let result = lines.joined(separator: "\n")
                NSLog("[MeetingClient] Merge: %d utterances", utterances.count)
                return result.isEmpty ? nil : result
            }
        } catch {
            NSLog("[MeetingClient] merge error: %@", "\(error)")
        }
        return nil
    }

    // MARK: - /transcribe — full pipeline (for final / file upload)

    /// POST /transcribe — full pipeline with diarization + optional summary.
    static func transcribe(audioData: Data, language: String, summarize: Bool = true) async -> MeetingTranscript? {
        let settings = AppSettings.shared
        guard let url = makeURL("/transcribe") else { return nil }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n")
        if settings.meetingNumSpeakers > 0 {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"num_speakers\"\r\n\r\n\(settings.meetingNumSpeakers)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"summarize\"\r\n\r\n\(summarize)\r\n")
        append("--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parseResponse(data)
        } catch {
            NSLog("[MeetingClient] transcribe error: %@", "\(error)")
        }
        return nil
    }

    // MARK: - /summarize — summarize accumulated transcript text

    /// POST /summarize — send accumulated text, get summary + action items.
    static func summarize(transcript: String) async -> (summary: String, actionItems: [String])? {
        guard let url = makeURL("/summarize") else { return nil }

        let payload: [String: Any] = ["transcript": transcript]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let summary = json["summary"] as? String ?? ""
                let items = json["action_items"] as? [String] ?? []
                NSLog("[MeetingClient] Summary received (%d chars)", summary.count)
                return (summary, items)
            }
        } catch {
            NSLog("[MeetingClient] summarize error: %@", "\(error)")
        }
        return nil
    }

    /// GET /health — check if server is reachable.
    static func healthCheck() async -> Bool {
        let settings = AppSettings.shared
        let endpoint = settings.meetingServerEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        NSLog("[MeetingClient] healthCheck endpoint: '%@'", endpoint)
        guard let url = URL(string: "\(endpoint)/health") else {
            NSLog("[MeetingClient] Invalid health URL from endpoint: '%@'", endpoint)
            return false
        }
        NSLog("[MeetingClient] healthCheck URL: %@", url.absoluteString)

        var req = URLRequest(url: url)
        req.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            NSLog("[MeetingClient] healthCheck HTTP %d", code)
            return code == 200
        } catch {
            NSLog("[MeetingClient] healthCheck error: %@", "\(error)")
            return false
        }
    }

    // MARK: - Helpers

    private static func makeURL(_ path: String) -> URL? {
        let endpoint = AppSettings.shared.meetingServerEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !endpoint.isEmpty else { return nil }
        return URL(string: "\(endpoint)\(path)")
    }

    // MARK: - Parse

    private static func parseResponse(_ data: Data) -> MeetingTranscript? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[MeetingClient] Failed to parse JSON response")
            return nil
        }

        guard let utterancesRaw = json["utterances"] as? [[String: Any]] else {
            NSLog("[MeetingClient] No utterances in response")
            return nil
        }

        let utterances = utterancesRaw.compactMap { u -> MeetingUtterance? in
            guard let speaker = u["speaker"] as? String,
                  let text = u["text"] as? String else { return nil }
            let timestamp = u["timestamp"] as? String
            return MeetingUtterance(speaker: speaker, text: text, timestamp: timestamp)
        }

        let summary = json["summary"] as? String
        let actionItems = json["action_items"] as? [String]

        NSLog("[MeetingClient] Received %d utterances", utterances.count)
        return MeetingTranscript(utterances: utterances, summary: summary, actionItems: actionItems)
    }
}
