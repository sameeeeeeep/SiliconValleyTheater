import Foundation

// MARK: - GroqClient

/// HTTP client for Groq's OpenAI-compatible API — blazingly fast LLM inference.
final class GroqClient: Sendable {
    let apiKey: String
    let model: String

    init(apiKey: String, model: String = "llama-3.3-70b-versatile") {
        self.apiKey = apiKey
        self.model = model
    }

    /// Generate a chat completion. Returns the response text.
    func generate(prompt: String, maxTokens: Int = 400) async throws -> String {
        guard !apiKey.isEmpty else {
            throw GroqError.noAPIKey
        }

        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw GroqError.invalidURL
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": maxTokens,
            "temperature": 0.9
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30 // Groq is fast, no need for 120s
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GroqError.noResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GroqError.httpError(http.statusCode, body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw GroqError.parseError
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if the API key works.
    func isAvailable() async -> Bool {
        guard !apiKey.isEmpty else { return false }
        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else { return false }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, resp) = try await URLSession.shared.data(for: request)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Errors

enum GroqError: LocalizedError {
    case noAPIKey
    case invalidURL
    case noResponse
    case httpError(Int, String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .noAPIKey: "No Groq API key configured"
        case .invalidURL: "Invalid Groq URL"
        case .noResponse: "No response from Groq"
        case .httpError(let code, let msg): "Groq HTTP \(code): \(msg)"
        case .parseError: "Could not parse Groq response"
        }
    }
}
