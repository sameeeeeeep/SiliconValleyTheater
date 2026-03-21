import Foundation

// MARK: - LLMClient Protocol

protocol LLMClient: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func isAvailable() async -> Bool
}

extension OllamaClient: LLMClient {}
extension GroqClient: LLMClient {}

// MARK: - Event Summarizer (zero-latency, no LLM)

/// Distills raw SessionEvents into a short, human-readable summary.
/// This eliminates 90% of the LLM's work — it just needs to write jokes, not understand code.
enum EventSummarizer {

    static func summarize(events: [SessionEvent]) -> String {
        var actions: [String] = []

        for event in events.prefix(8) {
            let d = event.detail.lowercased()
            let s = event.summary

            switch event.type {
            case .userMessage:
                // Extract what the user asked
                let ask = event.detail
                    .replacingOccurrences(of: "User asked: ", with: "")
                    .replacingOccurrences(of: "User: ", with: "")
                    .prefix(80)
                actions.append("User asked: \(ask)")

            case .assistantText:
                let explain = event.detail
                    .replacingOccurrences(of: "Claude explains: ", with: "")
                    .replacingOccurrences(of: "Claude: ", with: "")
                    .prefix(60)
                actions.append("Claude said: \(explain)")

            case .toolUse:
                if d.contains("read") || d.contains("reading") {
                    let file = extractFileName(from: event.detail)
                    actions.append("Opened \(file)")
                } else if d.contains("edit") || d.contains("writing") || d.contains("replacing") {
                    let file = extractFileName(from: event.detail)
                    let change = extractChange(from: event.detail)
                    actions.append("Changed \(file)\(change.isEmpty ? "" : " — \(change)")")
                } else if d.contains("bash") || d.contains("command") || d.contains("running") {
                    let cmd = extractCommand(from: event.detail)
                    actions.append("Ran command: \(cmd)")
                } else if d.contains("search") || d.contains("grep") || d.contains("glob") {
                    actions.append("Searched the codebase")
                } else {
                    let tool = s.prefix(50)
                    actions.append("Used tool: \(tool)")
                }

            case .toolResult:
                if d.contains("test") && d.contains("pass") {
                    let count = extractNumber(from: event.detail, near: "test")
                    actions.append("Tests passed\(count > 0 ? " (\(count) tests)" : "")")
                } else if d.contains("error") || d.contains("fail") {
                    let errMsg = event.detail.prefix(60)
                    actions.append("Got an error: \(errMsg)")
                } else if d.contains("success") || d.contains("complete") {
                    actions.append("Command succeeded")
                } else {
                    let result = event.detail.prefix(50)
                    actions.append("Result: \(result)")
                }

            case .thinking, .progress, .unknown:
                break // Skip non-actionable events
            }
        }

        // Deduplicate and limit
        let unique = actions.prefix(5)
        return unique.joined(separator: ". ")
    }

    // MARK: - Extraction Helpers

    private static func extractFileName(from detail: String) -> String {
        // Look for common file patterns
        let patterns = [
            "file ", "reading ", "editing ", "writing to ",
            "Reading file ", "Editing ", "Writing "
        ]
        for p in patterns {
            if let range = detail.range(of: p, options: .caseInsensitive) {
                let after = detail[range.upperBound...]
                let file = after.prefix(while: { !$0.isWhitespace && $0 != "—" && $0 != "-" && $0 != "," })
                if !file.isEmpty { return String(file) }
            }
        }
        // Try to find anything.ext pattern
        let words = detail.split(separator: " ")
        for w in words {
            if w.contains(".") && !w.hasPrefix("http") && w.count < 60 {
                let clean = w.trimmingCharacters(in: .punctuationCharacters)
                if clean.contains(".") { return clean }
            }
        }
        return "a file"
    }

    private static func extractChange(from detail: String) -> String {
        if let range = detail.range(of: "replacing", options: .caseInsensitive) {
            return String(detail[range.lowerBound...].prefix(60))
        }
        if let range = detail.range(of: "adding", options: .caseInsensitive) {
            return String(detail[range.lowerBound...].prefix(60))
        }
        if let range = detail.range(of: "removing", options: .caseInsensitive) {
            return String(detail[range.lowerBound...].prefix(60))
        }
        return ""
    }

    private static func extractCommand(from detail: String) -> String {
        let patterns = ["command: ", "Running command: ", "running: ", "Running "]
        for p in patterns {
            if let range = detail.range(of: p, options: .caseInsensitive) {
                return String(detail[range.upperBound...].prefix(40))
            }
        }
        return detail.prefix(40).description
    }

    private static func extractNumber(from detail: String, near keyword: String) -> Int {
        let words = detail.split(separator: " ")
        for (i, word) in words.enumerated() {
            if word.lowercased().contains(keyword), i > 0 {
                if let n = Int(words[i-1]) { return n }
            }
            if let n = Int(word), i + 1 < words.count, words[i+1].lowercased().contains(keyword) {
                return n
            }
        }
        return 0
    }
}


// MARK: - DialogueGenerator

/// Takes batches of SessionEvents, summarizes them (no LLM), then generates
/// character dialogue via a lightweight LLM prompt.
final class DialogueGenerator: Sendable {
    private let client: any LLMClient

    init(client: any LLMClient) {
        self.client = client
    }

    func generate(events: [SessionEvent], config: TheaterConfig) async throws -> [DialogueLine] {
        guard !events.isEmpty else { return [] }

        let prompt = buildPrompt(events: events, config: config)
        debugLog("[Generator] Prompt length: \(prompt.count) chars")
        let response = try await client.generate(prompt: prompt, maxTokens: 300)
        debugLog("[Generator] Raw response: \(response.prefix(300))")
        let names = config.characters.map(\.name)
        return DialogueParser.parse(response, names: names)
    }

    func isAvailable() async -> Bool {
        await client.isAvailable()
    }

    // MARK: - Prompt Building (Optimized for speed + quality)

    private func buildPrompt(events: [SessionEvent], config: TheaterConfig) -> String {
        let char0 = config.characters[0]
        let char1 = config.characters.count > 1 ? config.characters[1] : config.characters[0]

        // Pre-digest events into a short summary (zero latency)
        let summary = EventSummarizer.summarize(events: events)

        // Compact but structured prompt — forces character names and balances info + humor
        return """
        You are writing a script. Only output the 4 lines below, nothing else.

        CHARACTERS:
        \(char0.name) — \(char0.speechStyle.prefix(80))
        \(char1.name) — \(char1.speechStyle.prefix(80))

        WHAT JUST HAPPENED: \(summary)

        RULES:
        - Line 1: \(char0.name) explains what just happened in SIMPLE terms anyone can understand
        - Line 2: \(char1.name) reacts with a joke or analogy
        - Line 3: \(char0.name) adds technical detail but makes it fun
        - Line 4: \(char1.name) wraps up with a punchline
        - NEVER say "Claude" — they are \(char0.name) and \(char1.name), talking as if THEY did the work
        - Each line MUST start with the character name followed by a colon
        - Keep each line under 25 words

        \(char0.name):
        \(char1.name):
        \(char0.name):
        \(char1.name):
        """
    }
}
