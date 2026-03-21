import Foundation

// MARK: - OllamaClient

/// Minimal HTTP client for Ollama REST API at localhost:11434.
final class OllamaClient: Sendable {
    let baseURL: String
    let model: String

    init(baseURL: String = "http://localhost:11434", model: String = "qwen2.5:3b") {
        self.baseURL = baseURL
        self.model = model
    }

    /// Generate a completion. Returns the response text.
    func generate(prompt: String, maxTokens: Int = 1024) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaError.invalidURL
        }

        let payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "keep_alive": "5m",
            "options": ["num_predict": maxTokens]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.noResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.httpError(http.statusCode, body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String
        else {
            throw OllamaError.parseError
        }

        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if Ollama is running and reachable.
    func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Errors

enum OllamaError: LocalizedError {
    case invalidURL
    case noResponse
    case httpError(Int, String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Ollama URL"
        case .noResponse: "No response from Ollama"
        case .httpError(let code, let msg): "Ollama HTTP \(code): \(msg)"
        case .parseError: "Could not parse Ollama response"
        }
    }
}
