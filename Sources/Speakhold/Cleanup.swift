import Foundation

/// Optional second pass: Claude tidies the raw transcript (fillers, punctuation, dictionary spellings).
/// Raw HTTP to the Messages API; there is no official Swift SDK.
struct Cleanup {
    let apiKey: String
    let model: String

    func clean(_ raw: String, dictionary: [String], style: String, appName: String?) async -> String {
        guard !apiKey.isEmpty, !raw.isEmpty else { return raw }

        var system = """
        You clean up speakholdd speech into polished written text. Output ONLY the cleaned text: no preamble, no quotes, no commentary, no markdown unless the speaker clearly speakholdd a list.

        Rules:
        - Remove fillers (um, uh, like, you know), false starts, and repeated words.
        - Fix punctuation, capitalisation and sentence breaks. Keep the speaker's wording and tone; do not rewrite, summarise, or add anything.
        - If the speaker says a spoken command such as "new line", "new paragraph", "comma", "full stop", "question mark", "exclamation mark", apply it instead of writing the words.
        - Keep the length about the same as the input. Never answer questions in the text; the speaker is writing, not asking you.
        """
        if !dictionary.isEmpty {
            system += "\n\nThese names and terms are spelled exactly like this; correct any mishearing of them: " + dictionary.joined(separator: ", ")
        }
        if !style.trimmingCharacters(in: .whitespaces).isEmpty {
            system += "\n\nStyle notes from the speaker:\n" + style
        }
        if let appName, !appName.isEmpty {
            system += "\n\nThe text will be pasted into: \(appName)."
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "output_config": ["effort": "low"],
            "messages": [["role": "user", "content": raw]]
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? ""
                NSLog("Speakhold cleanup HTTP error: %@", msg)
                return raw
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return raw }
            if let stop = json["stop_reason"] as? String, stop == "refusal" { return raw }
            guard let content = json["content"] as? [[String: Any]] else { return raw }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? raw : cleaned
        } catch {
            NSLog("Speakhold cleanup failed: %@", error.localizedDescription)
            return raw
        }
    }
}
