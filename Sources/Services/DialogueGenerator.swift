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

    // Assistant narration that's just meta — "Let me...", "Now I'll...", "Running..."
    // We KEEP: explanations, decisions, questions to the user, plans
    private static func isNarration(_ text: String) -> Bool {
        let lower = text.lowercased()
        let narration = [
            "let me ", "now ", "running", "rebuilt", "rebuild", "here's what",
            "i'll ", "i can ", "i can't", "i need to ", "want me to",
            "let me wait", "let me check", "can you ", "open ",
            "built and running", "rebuilt and", "building", "compil",
        ]
        return narration.contains(where: { lower.hasPrefix($0) })
    }

    /// Target max chars for the summary — leaves room for examples + instructions in the prompt.
    /// Qwen 2.5 3B context is 32K tokens. Our prompt is ~1500 chars of instructions/examples.
    /// We want the summary to be rich but not overflow. 800 chars ≈ 200 tokens.
    private static let maxSummaryChars = 800

    static func summarize(events: [SessionEvent]) -> String {
        // WHAT MATTERS: the human-level conversation.
        // User asks → Claude explains/decides/questions → outcomes (pass/fail)
        // NOT: file diffs, tool calls, raw output, internal bookkeeping

        var lines: [String] = []

        for event in events.prefix(15) {
            let d = event.detail.lowercased()

            switch event.type {
            case .userMessage:
                let text = event.detail
                    .replacingOccurrences(of: "User asked: ", with: "")
                    .replacingOccurrences(of: "User: ", with: "")
                if text.hasPrefix("<command") || text.hasPrefix("Stop hook") { continue }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 { continue }
                lines.append("USER: \(text.prefix(250))")

            case .assistantText:
                let text = event.detail
                    .replacingOccurrences(of: "Claude explains: ", with: "")
                    .replacingOccurrences(of: "Claude said: ", with: "")
                    .replacingOccurrences(of: "Claude: ", with: "")
                if isNarration(text) { continue }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 { continue }
                // Keep substantive messages — explanations, decisions, questions, plans
                lines.append("CLAUDE: \(text.prefix(200))")

            case .toolUse:
                if d.contains("todowrite") || d.contains("todo") {
                    // Extract todo items — these are the plan
                    let items = extractTodoItems(from: event.detail)
                    if !items.isEmpty {
                        lines.append("PLAN: \(items)")
                    }
                } else if d.contains("enterplanmode") || d.contains("plan") {
                    lines.append("PLANNING: Designing the implementation approach before writing code")
                } else if d.contains("edit") || d.contains("writing") || d.contains("replacing") {
                    let file = shortFileName(from: event.detail)
                    lines.append("CHANGED: \(file)")
                } else if d.contains("bash") || d.contains("command") || d.contains("running") {
                    let raw = extractCommand(from: event.detail)
                    let lower = raw.lowercased()
                    if lower.contains("test") || lower.contains("build") || lower.contains("make")
                        || lower.contains("deploy") || lower.contains("install")
                        || lower.contains("npm run") || lower.contains("swift ") {
                        lines.append("RAN: \(raw.prefix(80))")
                    }
                }
                // Skip reads, searches, other internal tools

            case .toolResult:
                if d.contains("error") || d.contains("fail") || d.contains("exception") {
                    let errMsg = cleanErrorMessage(event.detail)
                    if !errMsg.isEmpty { lines.append("FAILED: \(errMsg)") }
                } else if d.contains("test") && d.contains("pass") {
                    lines.append("TESTS PASSED")
                } else if d.contains("built") || d.contains("compiled") {
                    lines.append("BUILD SUCCEEDED")
                }

            case .thinking, .progress, .unknown:
                continue
            }
        }

        // Deduplicate (e.g. multiple "CHANGED: same-file")
        var seen = Set<String>()
        lines = lines.filter { line in
            let key = String(line.prefix(30)).lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        // Assemble respecting char budget
        var summary = ""
        for line in lines {
            let candidate = summary.isEmpty ? line : summary + "\n" + line
            if candidate.count > maxSummaryChars { break }
            summary = candidate
        }

        return summary.isEmpty ? "Working on the codebase" : summary
    }

    private static func extractToolName(from detail: String) -> String {
        // detail looks like "Using ToolName: ..." or "Tool: ToolName — ..."
        let lower = detail.lowercased()
        for prefix in ["using ", "tool: "] {
            if let range = lower.range(of: prefix) {
                let after = lower[range.upperBound...]
                let name = after.prefix(while: { $0.isLetter || $0.isNumber })
                return String(name)
            }
        }
        return ""
    }

    /// Pull todo item descriptions out of TodoWrite event details
    private static func extractTodoItems(from detail: String) -> String {
        // TodoWrite details contain content/activeForm fields in the raw dict
        var items: [String] = []
        // Match "content = " or "content": patterns
        let patterns = [
            (try? NSRegularExpression(pattern: #"content\s*[=:]\s*"?([^";}\n]+)"?"#, options: [])),
            (try? NSRegularExpression(pattern: #"activeForm\s*[=:]\s*"?([^";}\n]+)"?"#, options: [])),
        ]
        for regex in patterns.compactMap({ $0 }) {
            let matches = regex.matches(in: detail, range: NSRange(detail.startIndex..., in: detail))
            for match in matches.prefix(5) {
                if match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: detail) {
                    let item = String(detail[range]).trimmingCharacters(in: .whitespaces)
                    if item.count > 5 && !items.contains(item) {
                        items.append(item)
                    }
                }
            }
        }
        if items.isEmpty {
            // Fallback: just grab a snippet
            return String(detail.prefix(120))
        }
        return items.prefix(4).joined(separator: ", ")
    }

    private static func extractPattern(from detail: String) -> String {
        let markers = ["pattern", "searching for", "finding files matching", "'"]
        for p in markers {
            if let range = detail.range(of: p, options: .caseInsensitive) {
                let after = detail[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let snippet = String(after.prefix(40).prefix(while: { $0 != "'" && $0 != "\n" }))
                if !snippet.isEmpty { return "'\(snippet)'" }
            }
        }
        return "code patterns"
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

    /// Convert raw bash commands into human-readable descriptions.
    /// Always includes the actual command so the LLM can reference specifics.
    private static func humanizeCommand(from detail: String) -> String {
        let raw = extractCommand(from: detail)
        let cmd = raw.lowercased()
        let short = String(raw.prefix(60))

        if cmd.contains("npm test") || cmd.contains("swift test") || cmd.contains("pytest") || cmd.contains("jest") {
            return "Ran the test suite (\(short))"
        } else if cmd.contains("npm install") || cmd.contains("pip install") || cmd.contains("brew install") {
            return "Installed dependencies (\(short))"
        } else if cmd.contains("npm run build") || cmd.contains("make build") || cmd.contains("swift build") || cmd.contains("make clean") {
            return "Built the project (\(short))"
        } else if cmd.contains("git commit") {
            return "Made a git commit (\(short))"
        } else if cmd.contains("git ") {
            return "Git: \(short)"
        } else if cmd.contains("npm run dev") || cmd.contains("npm start") {
            return "Started the dev server (\(short))"
        } else if cmd.contains("grep") || cmd.contains("find") || cmd.contains("rg ") {
            return "Searched with: \(short)"
        } else if cmd.contains("ls") || cmd.contains("cat") || cmd.contains("head") || cmd.contains("tail") {
            return "Inspected files (\(short))"
        } else {
            return "Ran: \(short)"
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

    func generate(events: [SessionEvent], config: TheaterConfig, activeTheme: CharacterTheme? = nil, theaterContext: TheaterContext? = nil) async throws -> [DialogueLine] {
        guard !events.isEmpty else { return [] }

        let prompt = buildPrompt(events: events, config: config, theme: activeTheme, theaterContext: theaterContext)
        debugLog("[Generator] Prompt length: \(prompt.count) chars")
        debugLog("[Generator] === FULL PROMPT ===\n\(prompt)\n=== END PROMPT ===")
        let response = try await client.generate(prompt: prompt, maxTokens: 350)
        debugLog("[Generator] Raw response: \(response.prefix(400))")
        let names = config.characters.map(\.name)
        return DialogueParser.parse(response, names: names)
    }

    /// Generate filler banter — contextual to recent events when available.
    /// Returns dialogue lines that can be voice-cached for instant playback.
    /// The first line should be a natural lead-in ("this reminds me of...", "speaking of which...").
    func generateFiller(config: TheaterConfig, activeTheme: CharacterTheme? = nil, recentContext: String? = nil) async throws -> [DialogueLine] {
        let c0 = config.characters[0]
        let c1 = config.characters.count > 1 ? config.characters[1] : config.characters[0]

        let topics = [
            "They riff about a funny bug they once encountered — something absurd that took hours to find.",
            "They argue about tabs vs spaces, or which programming language is superior.",
            "They reminisce about a disastrous deploy that went wrong in a hilarious way.",
            "They debate whether their current project is genius or a complete waste of time.",
            "One tells a story about the worst code review they ever received.",
            "They compete over who wrote the worst code in the codebase.",
            "They argue about whether AI will replace programmers, and what they'd do instead.",
            "One confesses to a terrible naming convention they used and defends it passionately.",
            "They debate the proper way to handle error messages — helpful or sarcastic.",
            "They tell horror stories about production databases they accidentally wiped.",
            "They argue over the best time of day to write code. Early morning vs late night.",
            "One tries to explain their side project and the other keeps finding flaws.",
            "They debate whether documentation is actually useful or just performative.",
            "They reenact a terrible standup meeting they once attended.",
            "They argue about whether Stack Overflow or ChatGPT is the better copilot.",
            "One describes the most cursed legacy code they ever inherited.",
            "They debate whether meetings could always just be emails.",
            "They trade stories about the weirdest things they've found in code comments.",
            "They argue about coffee vs energy drinks as the optimal coding fuel.",
            "One tries to justify their excessive use of global variables.",
            "They debate whether you should ever trust code that works on the first try.",
            "They reminisce about their first ever programming project and how terrible it was.",
        ]
        let topic = topics.randomElement()!

        let example = activeTheme?.fewShotExample ?? ""

        let contextLine: String
        if let ctx = recentContext, !ctx.isEmpty {
            contextLine = """
            The developers are currently working on: \(ctx)
            The banter should loosely relate to what they're doing — make the first line a natural lead-in like \
            "this reminds me of..." or "speaking of which..." or "you know what this is like?" or tell a story \
            that relates to the current work. Don't reference the events directly, just use them for thematic inspiration.
            """
        } else {
            contextLine = """
            Topic: \(topic)
            Start with a natural lead-in line — like \(c0.name) telling a story: "this reminds me of the time..." \
            or "you know what, I had an intern once who..." — then the other character reacts and they riff on it.
            """
        }

        let prompt = """
        Write exactly 6 lines of funny banter between \(c0.name) and \(c1.name). They're killing time between tasks.
        \(contextLine)
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

    /// Generate a term explainer for a specific technical concept.
    /// Returns 6 lines explaining the term in character, using a fun analogy.
    func generateTermExplainer(term: String, config: TheaterConfig, activeTheme: CharacterTheme? = nil) async throws -> [DialogueLine] {
        let c0 = config.characters[0]
        let c1 = config.characters.count > 1 ? config.characters[1] : config.characters[0]
        let example = activeTheme?.fewShotExample ?? ""

        let prompt = """
        Write exactly 6 lines where \(c0.name) and \(c1.name) explain what "\(term)" means in software development.
        Use a fun, accessible analogy that a non-programmer would understand. Stay in character. Under 25 words each line.
        Character name and colon to start each line.

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

    private func buildPrompt(events: [SessionEvent], config: TheaterConfig, theme: CharacterTheme? = nil, theaterContext: TheaterContext? = nil) -> String {
        let c0 = config.characters[0]
        let c1 = config.characters.count > 1 ? config.characters[1] : config.characters[0]

        // Pre-digest events into a short summary (zero latency)
        let summary = EventSummarizer.summarize(events: events)

        // RAG: pick the best example from theater.md if available, else fall back to theme's hardcoded example
        let example: String
        if let ctx = theaterContext, let matched = ctx.bestExample(forEvents: summary) {
            example = matched
            debugLog("[Generator] Using theater.md example (RAG-matched)")
        } else {
            example = theme?.fewShotExample ?? """
            EXAMPLE:
            \(c0.name): We just ripped cookieStore.get out of auth.swift. Remember last time someone left session cookies in prod? Three-day outage.
            \(c1.name): That was the intern. He stored sessions in a JSON file on the desktop. DESKTOP.
            \(c0.name): jwt.verify is cleaner. Verify, decode, done. No database roundtrip. No desktop JSON files.
            \(c1.name): Twelve tests passed. I once saw a team skip auth tests entirely. They got hacked on launch day.
            \(c0.name): Classic. The CEO tweeted 'we take security seriously' while their admin password was 'password123.'
            \(c1.name): Twelve for twelve. cookieStore is dead. I'm not writing the obituary though.
            """
        }

        // Project context from theater.md (short — keeps the 3B model focused)
        let projectLine: String
        if let ctx = theaterContext {
            projectLine = "\nPROJECT: \(ctx.projectContext())\n"
        } else {
            projectLine = ""
        }

        return """
        Write 6 lines of dialogue. \(c0.name) and \(c1.name) react to what JUST happened below.
        \(projectLine)
        RULES:
        - Reference SPECIFIC details from the events: filenames, function names, commands, error messages
        - The first line MUST mention something concrete from the summary (a file, a command, a change)
        - DON'T use "it's like..." analogies — instead tell INCIDENTS: "this reminds me of the time when...", "remember when...", "I once saw..."
        - React to each other, argue, one-up, take credit, assign blame
        - Stay in character. Under 25 words each line
        - Never say "Claude", never quote full file paths

        \(example)

        NOW — here is the actual event log from the coding session:
        \(summary)

        React to these events. Tell the user what happened and why it matters. Write the dialogue:
        \(c0.name):
        \(c1.name):
        \(c0.name):
        \(c1.name):
        \(c0.name):
        \(c1.name):
        """
    }
}
