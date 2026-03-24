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
    /// We want the summary to be rich but not overflow. 1800 chars ≈ 450 tokens.
    /// Increased from 1200 to preserve assistant explanations which are the key to ELI5 dialogue.
    private static let maxSummaryChars = 1800

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
                var text = event.detail
                    .replacingOccurrences(of: "Claude explains: ", with: "")
                    .replacingOccurrences(of: "Claude said: ", with: "")
                    .replacingOccurrences(of: "Claude: ", with: "")
                // Strip markdown artifacts that waste summary budget
                text = text.replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "##", with: "")
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "```", with: "")
                if isNarration(text) { continue }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 { continue }
                // Keep substantive messages — explanations, decisions, questions, plans
                lines.append("ASSISTANT: \(text.prefix(250))")

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
                    // Include what was changed — the detail often has old/new strings
                    let changeDesc = extractChange(from: event.detail)
                    if !changeDesc.isEmpty {
                        lines.append("CHANGED: \(file) — \(changeDesc)")
                    } else {
                        lines.append("CHANGED: \(file)")
                    }
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

        // First try: build ELI5 dialogue purely from the event summary (no LLM).
        // Claude's assistant text already explains what happened — we just reformat it.
        let summary = EventSummarizer.summarize(events: events)
        let c0 = config.characters[0]
        let c1 = config.characters.count > 1 ? config.characters[1] : config.characters[0]
        let userName = activeTheme?.userCharacterName ?? "Richard"
        let templateLines = buildTemplateDialogue(from: summary, c0: c0, c1: c1, userName: userName)

        if templateLines.count >= 3 {
            // Template produced enough ELI5 content — use it directly, skip LLM
            debugLog("[Generator] Using template dialogue (\(templateLines.count) lines, no LLM)")
            for line in templateLines {
                let name = config.characters[min(line.characterIndex, config.characters.count - 1)].name
                debugLog("[Generator]   \(name): \(line.text.prefix(60))")
            }
            return templateLines
        }

        // Fallback: not enough template content — use LLM
        let prompt = buildPrompt(events: events, config: config, theme: activeTheme, theaterContext: theaterContext)
        debugLog("[Generator] Template insufficient (\(templateLines.count) lines), using LLM")
        debugLog("[Generator] Prompt length: \(prompt.count) chars")
        debugLog("[Generator] === FULL PROMPT ===\n\(prompt)\n=== END PROMPT ===")
        let response = try await client.generate(prompt: prompt, maxTokens: 350)
        debugLog("[Generator] Raw response: \(response.prefix(400))")
        let names = config.characters.map(\.name)
        return DialogueParser.parse(response, names: names)
    }

    /// Build ELI5 dialogue directly from the event summary — no LLM needed.
    /// Reformats Claude's actual explanations into a character back-and-forth.
    /// Returns 3-6 lines if there's enough content, or empty if summary is too thin.
    private func buildTemplateDialogue(from summary: String, c0: CharacterConfig, c1: CharacterConfig, userName: String) -> [DialogueLine] {
        let lines = summary.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var dialogue: [DialogueLine] = []
        var turn = 0 // alternates 0, 1, 0, 1...

        // Extract pieces
        var userAsk: String?
        var explanations: [String] = []
        var changes: [String] = []
        var outcome: String?

        for line in lines {
            if line.hasPrefix("USER:") {
                let text = String(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                if !Self.isMetaConversation(text) && text.count > 10 {
                    userAsk = String(text.prefix(80))
                }
            } else if line.hasPrefix("ASSISTANT:") {
                let text = String(line.dropFirst(10).trimmingCharacters(in: .whitespaces))
                if Self.isTechnicalExplanation(text) && text.count > 30 {
                    explanations.append(String(text.prefix(150)))
                }
            } else if line.hasPrefix("CHANGED:") {
                changes.append(String(line.dropFirst(8).trimmingCharacters(in: .whitespaces).prefix(80)))
            } else if line.hasPrefix("FAILED:") {
                outcome = "failed: " + String(line.dropFirst(7).trimmingCharacters(in: .whitespaces).prefix(60))
            } else if line.hasPrefix("TESTS PASSED") {
                outcome = "tests passed"
            } else if line.hasPrefix("BUILD SUCCEEDED") {
                outcome = "build succeeded"
            } else if line.hasPrefix("PLAN:") {
                let plan = String(line.dropFirst(5).trimmingCharacters(in: .whitespaces).prefix(100))
                explanations.append("The plan is: \(plan)")
            }
        }

        // Line 1: What the user asked (if available)
        if let ask = userAsk {
            dialogue.append(DialogueLine(
                characterIndex: turn % 2,
                text: "\(userName) wants us to \(ask.lowercased().trimmingCharacters(in: .punctuationCharacters))."
            ))
            turn += 1
        }

        // Line 2-3: The explanation (the ELI5 core)
        for explanation in explanations.prefix(2) {
            // Split long explanations into two shorter lines
            if explanation.count > 80, let splitPoint = findSplitPoint(in: explanation) {
                let part1 = String(explanation.prefix(splitPoint)).trimmingCharacters(in: .whitespaces)
                let part2 = String(explanation.dropFirst(splitPoint)).trimmingCharacters(in: .whitespaces)
                dialogue.append(DialogueLine(characterIndex: turn % 2, text: part1))
                turn += 1
                if !part2.isEmpty {
                    dialogue.append(DialogueLine(characterIndex: turn % 2, text: part2.first?.isUppercase == true ? part2 : part2.prefix(1).uppercased() + part2.dropFirst()))
                    turn += 1
                }
            } else {
                dialogue.append(DialogueLine(characterIndex: turn % 2, text: explanation))
                turn += 1
            }
        }

        // Line 4: What changed
        if let change = changes.first, dialogue.count < 6 {
            dialogue.append(DialogueLine(
                characterIndex: turn % 2,
                text: "We changed \(change)."
            ))
            turn += 1
        }

        // Line 5-6: Outcome
        if let result = outcome, dialogue.count < 6 {
            switch result {
            case "tests passed":
                dialogue.append(DialogueLine(characterIndex: turn % 2, text: "Tests passed. All of them."))
            case "build succeeded":
                dialogue.append(DialogueLine(characterIndex: turn % 2, text: "Build went through. No errors."))
            default:
                if result.hasPrefix("failed") {
                    dialogue.append(DialogueLine(characterIndex: turn % 2, text: result.prefix(1).uppercased() + result.dropFirst() + "."))
                }
            }
        }

        return dialogue
    }

    /// Find a good split point in a long string (period, comma, dash, or "but"/"and"/"so").
    private func findSplitPoint(in text: String) -> Int? {
        let midpoint = text.count / 2
        let searchRange = max(0, midpoint - 20)...min(text.count - 1, midpoint + 20)

        // Prefer splitting at sentence connectors
        for separator in [". ", " but ", " — ", ", ", " and ", " so "] {
            if let range = text.range(of: separator, range: text.index(text.startIndex, offsetBy: searchRange.lowerBound)..<text.index(text.startIndex, offsetBy: min(searchRange.upperBound, text.count))) {
                return text.distance(from: text.startIndex, to: range.upperBound)
            }
        }
        return nil
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

    /// Pick one concrete anchor topic from the summary for the 3B model to focus on.
    /// Without this, it scatters across every detail and produces disconnected lines.
    /// Returns a clean, natural description — not raw event labels like "RAN:" which confuse the model.
    private func pickAnchor(from summary: String) -> String {
        let lines = summary.components(separatedBy: .newlines).filter { !$0.isEmpty }

        // Priority: errors > user messages > commands > file changes > fallback
        // Strip the event label prefix so the model gets natural text
        for line in lines {
            if line.hasPrefix("FAILED:") {
                return "a failure: " + String(line.dropFirst(7).trimmingCharacters(in: .whitespaces).prefix(60))
            }
        }
        for line in lines {
            if line.hasPrefix("USER:") {
                return "the user saying: " + String(line.dropFirst(5).trimmingCharacters(in: .whitespaces).prefix(60))
            }
        }
        for line in lines {
            if line.hasPrefix("ASSISTANT:") {
                return String(line.dropFirst(10).trimmingCharacters(in: .whitespaces).prefix(60))
            }
        }
        for line in lines {
            if line.hasPrefix("BUILD") || line.hasPrefix("TESTS") {
                return String(line.prefix(60)).lowercased()
            }
        }
        for line in lines {
            if line.hasPrefix("RAN:") {
                return "running: " + String(line.dropFirst(4).trimmingCharacters(in: .whitespaces).prefix(60))
            }
        }
        for line in lines {
            if line.hasPrefix("CHANGED:") {
                return "changing " + String(line.dropFirst(8).trimmingCharacters(in: .whitespaces).prefix(60))
            }
        }
        return "the latest code changes"
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
            \(c0.name): They just swapped out the auth system. Brave.
            \(c1.name): Brave? The old one was held together with tape.
            \(c0.name): Twelve tests passed. That's suspicious.
            \(c1.name): I once saw a build pass on Friday. Server died Monday.
            \(c0.name): Classic. At least they checked before pushing.
            \(c1.name): Progress. Actual progress. Mark the calendar.
            """
        }

        // Project context from theater.md (short — keeps the 3B model focused)
        let projectLine: String
        if let ctx = theaterContext {
            projectLine = "\nPROJECT: \(ctx.projectContext())\n"
        } else {
            projectLine = ""
        }

        // Pick ONE concrete detail from the summary for the model to anchor on.
        // This prevents the 3B model from scattering across unrelated topics.
        let anchor = pickAnchor(from: summary)
        let userName = theme?.userCharacterName ?? "Richard"

        // Seed 2-3 lines that convey the situation accurately.
        // The 3B model only needs to continue with reactions and stories.
        let seedLines = buildSeedLines(from: summary, anchor: anchor, c0: c0, c1: c1, userName: userName)
        let hasSeeds = !seedLines.isEmpty

        if hasSeeds {
            let seedCount = seedLines.components(separatedBy: .newlines).count
            let continuationCount = max(3, 6 - seedCount)
            var continuationTemplate = ""
            for i in 0..<continuationCount {
                let char = (i % 2 == 0) ? ((seedCount % 2 == 0) ? c0.name : c1.name) : ((seedCount % 2 == 0) ? c1.name : c0.name)
                continuationTemplate += "\(char):\n"
            }

            return """
            \(c0.name) and \(c1.name) are working on a project together. They talk as if THEY are doing the work.
            \(projectLine)
            RULES:
            - Continue the conversation below. Write \(continuationCount) more lines
            - They RESPOND to each other. Each line reacts to the previous one
            - Max 20 words per line. Short and punchy
            - Talk about what you DID and WHY. Tell quick stories from past experience
            - Never say "Claude". The developer is called \(userName)

            \(example)

            WHAT HAPPENED:
            \(summary)

            Continue this conversation about \(anchor):
            \(seedLines)
            \(continuationTemplate)
            """
        } else {
            // No clean seed lines — let the example carry and ask model to write all 6
            return """
            \(c0.name) and \(c1.name) are working on a project together. They talk as if THEY are doing the work.
            \(projectLine)
            RULES:
            - Write 6 lines about what just happened. \(c0.name) and \(c1.name) alternate
            - They RESPOND to each other. Each line reacts to the previous one
            - Max 20 words per line. Short and punchy
            - Talk about what you DID and WHY. Tell quick stories from past experience
            - Never say "Claude". The developer is called \(userName)

            \(example)

            WHAT HAPPENED:
            \(summary)

            Write about \(anchor):
            \(c0.name):
            \(c1.name):
            \(c0.name):
            \(c1.name):
            \(c0.name):
            \(c1.name):
            """
        }
    }

    /// Build 2-3 seed lines from the summary so the 3B model starts strong.
    /// The model is much better at continuing good lines than writing from scratch.
    /// We do the "understanding" work here; the model just adds character reactions.
    private func buildSeedLines(from summary: String, anchor: String, c0: CharacterConfig, c1: CharacterConfig, userName: String) -> String {
        let lines = summary.components(separatedBy: .newlines).filter { !$0.isEmpty }

        // Extract key pieces from the summary
        var userAsk: String?
        var assistantExplanation: String?
        var change: String?
        var outcome: String?

        // Collect assistant lines, filtering out meta-conversation and debug output.
        var assistantCandidates: [String] = []

        for line in lines {
            if line.hasPrefix("USER:") && userAsk == nil {
                let text = String(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                // Skip meta-conversation about the app itself
                if !Self.isMetaConversation(text) {
                    userAsk = String(text.prefix(80))
                }
            } else if line.hasPrefix("ASSISTANT:") {
                let text = String(line.dropFirst(10).trimmingCharacters(in: .whitespaces))
                // Only keep genuine technical explanations, not meta/debug text
                if text.count > 40 && Self.isTechnicalExplanation(text) {
                    assistantCandidates.append(text)
                }
            } else if line.hasPrefix("CHANGED:") && change == nil {
                change = String(line.dropFirst(8).trimmingCharacters(in: .whitespaces).prefix(80))
            } else if line.hasPrefix("FAILED:") {
                outcome = "FAILED: " + String(line.dropFirst(7).trimmingCharacters(in: .whitespaces).prefix(60))
            } else if line.hasPrefix("TESTS PASSED") || line.hasPrefix("BUILD SUCCEEDED") {
                outcome = line
            }
        }

        // Pick the best assistant explanation — longest one that passes our filters
        assistantExplanation = assistantCandidates.max(by: { $0.count < $1.count }).map { String($0.prefix(120)) }

        // Build 2-3 seed lines that convey the situation accurately.
        var seeds: [String] = []

        // Only seed user ask if it's a clear technical request
        if let ask = userAsk {
            seeds.append("\(c0.name): \(userName) wants us to \(ask.lowercased().trimmingCharacters(in: .punctuationCharacters)). On it.")
        }

        if let explanation = assistantExplanation {
            // This is the ELI5 core — Claude's actual explanation of what happened
            seeds.append("\(c1.name): So what happened was — \(explanation)")
        } else if let ch = change {
            seeds.append("\(c1.name): We just changed \(ch).")
        }

        if let result = outcome {
            if result.hasPrefix("FAILED") {
                let detail = String(result.dropFirst(8).prefix(50))
                seeds.append("\(c0.name): And it FAILED. \(detail). I don't love that.")
            } else if result.contains("PASSED") {
                seeds.append("\(c0.name): And it passed. All of it. I don't trust it but it passed.")
            } else if result.contains("SUCCEEDED") {
                seeds.append("\(c0.name): Build went through. No errors. Suspicious but I'll take it.")
            }
        }

        // Fallback — don't seed garbage, just let the example carry
        if seeds.isEmpty {
            return ""
        }

        return seeds.joined(separator: "\n")
    }

    /// Detect meta-conversation about the app/tool itself vs actual coding requests.
    /// Meta: "why is cache repeating", "the voices are wrong", "check the logs"
    /// Real: "fix the opacity", "add JWT auth", "refactor the pipeline"
    private static func isMetaConversation(_ text: String) -> Bool {
        let lower = text.lowercased()
        let metaPatterns = [
            "why is it", "why did it", "check the log", "what does it",
            "the voices", "its saying", "it's saying", "are we not",
            "can you add", "can we ensure", "i feel you", "also i",
            "irrespective", "how are we", "what architecture",
            "is this explaining", "also check", "also with",
            "lets test", "let's test", "open app", "reopen",
            "screwed something", "not working", "broken",
        ]
        return metaPatterns.contains(where: { lower.contains($0) })
    }

    /// Check if assistant text is a genuine technical explanation vs debug/meta output.
    /// Good: "the clip-path crops to the left half but we're sampling from the wrong side"
    /// Bad: "Found it. At 10:28:55 it played a static filler", "Let me check the logs"
    private static func isTechnicalExplanation(_ text: String) -> Bool {
        let lower = text.lowercased()

        // Reject: debug output, log references, timestamps, meta-responses
        let rejectPatterns = [
            "let me check", "let me look", "let me see", "let me test",
            "here's what", "i can see", "i see the",
            "found it", "looking at", "checking",
            "10:", "11:", "12:", "1:", "2:", "3:", "4:", "5:", "6:", "7:", "8:", "9:",  // timestamps
            "debug.log", "grep", "tail -", "head -",
            "`", "```",  // code blocks
            "the logs show", "the log says", "in the logs",
            "you're right", "good point", "fair point",
            "yeah", "hmm", "okay so the", "sure,",
        ]
        if rejectPatterns.contains(where: { lower.contains($0) }) { return false }

        // Accept: text that explains what/why/how about code
        let acceptPatterns = [
            "because", "the problem", "the issue", "the fix",
            "instead of", "replacing", "changed", "updated", "added", "removed",
            "this means", "so that", "which means",
            "the function", "the file", "the class", "the method",
            "we need to", "this will", "now it",
            "was missing", "was wrong", "was broken",
            "imports", "framework", "module", "component",
        ]
        if acceptPatterns.contains(where: { lower.contains($0) }) { return true }

        // Default: accept if long enough (likely substantive)
        return text.count > 80
    }
}
