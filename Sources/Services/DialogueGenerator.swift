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

        for event in events.prefix(20) {
            let d = event.detail.lowercased()

            switch event.type {
            case .userMessage:
                let ask = event.detail
                    .replacingOccurrences(of: "User asked: ", with: "")
                    .replacingOccurrences(of: "User: ", with: "")
                    .prefix(80)
                actions.append("The developer asked: \(ask)")

            case .assistantText:
                let explain = event.detail
                    .replacingOccurrences(of: "Claude explains: ", with: "")
                    .replacingOccurrences(of: "Claude: ", with: "")
                    .prefix(60)
                actions.append("Explanation: \(explain)")

            case .toolUse:
                if d.contains("read") || d.contains("reading") {
                    let file = shortFileName(from: event.detail)
                    actions.append("Opened the \(file) file")
                } else if d.contains("edit") || d.contains("writing") || d.contains("replacing") {
                    let file = shortFileName(from: event.detail)
                    let change = extractChange(from: event.detail)
                    if !change.isEmpty {
                        actions.append("Edited \(file) — \(change)")
                    } else {
                        actions.append("Made changes to \(file)")
                    }
                } else if d.contains("bash") || d.contains("command") || d.contains("running") {
                    let cmd = humanizeCommand(from: event.detail)
                    actions.append(cmd)
                } else if d.contains("search") || d.contains("grep") || d.contains("glob") {
                    actions.append("Searched through the codebase")
                } else {
                    // Generic tool use — describe the action, not the tool name
                    actions.append("Performed an operation on the code")
                }

            case .toolResult:
                if d.contains("test") && d.contains("pass") {
                    let count = extractNumber(from: event.detail, near: "test")
                    actions.append("All tests passed\(count > 0 ? " — \(count) total" : "")")
                } else if d.contains("error") || d.contains("fail") {
                    // Extract just the meaningful error, not the full path
                    let errMsg = cleanErrorMessage(event.detail)
                    actions.append("Hit an error: \(errMsg)")
                } else if d.contains("success") || d.contains("complete") {
                    actions.append("That worked successfully")
                } else {
                    break // Skip generic results
                }

            case .thinking, .progress, .unknown:
                break
            }
        }

        let unique = actions.prefix(8)
        return unique.joined(separator: ". ")
    }

    /// Strip full paths down to just the filename (e.g. "auth.swift" not "/Users/foo/bar/auth.swift")
    private static func shortFileName(from detail: String) -> String {
        let raw = extractFileName(from: detail)
        // Strip path — keep only filename
        if raw.contains("/") {
            return String(raw.split(separator: "/").last ?? Substring(raw))
        }
        return raw
    }

    /// Convert raw bash commands into human-readable descriptions
    private static func humanizeCommand(from detail: String) -> String {
        let cmd = extractCommand(from: detail).lowercased()
        if cmd.contains("npm test") || cmd.contains("swift test") || cmd.contains("pytest") || cmd.contains("jest") {
            return "Ran the test suite"
        } else if cmd.contains("npm install") || cmd.contains("pip install") || cmd.contains("brew install") {
            return "Installed some dependencies"
        } else if cmd.contains("npm run build") || cmd.contains("make build") || cmd.contains("swift build") {
            return "Built the project"
        } else if cmd.contains("git ") {
            return "Did some version control work"
        } else if cmd.contains("npm run dev") || cmd.contains("npm start") {
            return "Started the development server"
        } else {
            return "Ran a command"
        }
    }

    /// Clean error messages — strip paths, keep the meaningful part
    private static func cleanErrorMessage(_ detail: String) -> String {
        var msg = detail
        // Remove file paths
        let pathPattern = try? NSRegularExpression(pattern: "/[\\w/.-]+/", options: [])
        msg = pathPattern?.stringByReplacingMatches(in: msg, range: NSRange(msg.startIndex..., in: msg), withTemplate: "") ?? msg
        // Trim to reasonable length
        return String(msg.prefix(50))
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
    let client: any LLMClient

    init(client: any LLMClient) {
        self.client = client
    }

    func generate(events: [SessionEvent], config: TheaterConfig, activeTheme: CharacterTheme? = nil) async throws -> [DialogueLine] {
        guard !events.isEmpty else { return [] }

        let prompt = buildPrompt(events: events, config: config, theme: activeTheme)
        debugLog("[Generator] Prompt length: \(prompt.count) chars")
        let response = try await client.generate(prompt: prompt, maxTokens: 350)
        debugLog("[Generator] Raw response: \(response.prefix(400))")
        let names = config.characters.map(\.name)
        return DialogueParser.parse(response, names: names)
    }

    /// Generate filler banter (no events needed) — used during idle time.
    /// Returns dialogue lines that can be voice-cached for instant playback.
    func generateFiller(config: TheaterConfig, activeTheme: CharacterTheme? = nil) async throws -> [DialogueLine] {
        let c0 = config.characters[0]
        let c1 = config.characters.count > 1 ? config.characters[1] : config.characters[0]

        let topics = [
            "They riff about a funny bug they once encountered — something absurd that took hours to find.",
            "They argue about tabs vs spaces, or which programming language is superior.",
            "They reminisce about a disastrous deploy that went wrong in a hilarious way.",
            "They debate whether their current project is genius or a complete waste of time.",
            "One tells a story about the worst code review they ever received.",
            "They compete over who wrote the worst code in the codebase.",
        ]
        let topic = topics.randomElement()!

        let example = activeTheme?.fewShotExample ?? ""

        let prompt = """
        Write exactly 6 lines of funny banter between \(c0.name) and \(c1.name). No real events — just two characters killing time.
        Topic: \(topic)
        Stay in character. Under 25 words each line. Character name and colon to start each line.

        \(example)

        \(c0.name):
        \(c1.name):
        \(c0.name):
        \(c1.name):
        \(c0.name):
        \(c1.name):
        """

        let response = try await client.generate(prompt: prompt, maxTokens: 400)
        let names = config.characters.map(\.name)
        return DialogueParser.parse(response, names: names)
    }

    func isAvailable() async -> Bool {
        await client.isAvailable()
    }

    // MARK: - Prompt Building (Few-shot, optimized for speed + quality)

    private func buildPrompt(events: [SessionEvent], config: TheaterConfig, theme: CharacterTheme? = nil) -> String {
        let c0 = config.characters[0]
        let c1 = config.characters.count > 1 ? config.characters[1] : config.characters[0]

        // Pre-digest events into a short summary (zero latency)
        let summary = EventSummarizer.summarize(events: events)

        // Use theme-specific few-shot example if available
        let example = theme?.fewShotExample ?? """
        EXAMPLE (event: Changed auth.swift — replacing cookies with JWT. Tests passed 12):
        \(c0.name): We just swapped the locks from physical keys to digital key cards. Much harder to pick.
        \(c1.name): Twelve tests passed. Twelve doors we didn't accidentally brick.
        \(c0.name): Session cookies were like hiding your house key under the doormat. JWT is a real deadbolt.
        \(c1.name): Now explain that to the product manager without saying the word token.
        \(c0.name): It expires on its own, no database needed, and you can't forge it without the secret key.
        \(c1.name): So we replaced a sticky note on the fridge with an actual security system. About time.
        """

        return """
        Write 6 lines. \(c0.name) and \(c1.name) react to what just happened. Explain what it means simply. Stay in character. Under 25 words each. Never mention Claude or file paths.

        \(example)

        NOW (\(summary)):
        \(c0.name):
        \(c1.name):
        \(c0.name):
        \(c1.name):
        \(c0.name):
        \(c1.name):
        """
    }
}
