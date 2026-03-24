import Foundation

// MARK: - TheaterContext

/// Loads and parses a project's .claude/theater.md file for project-aware commentary.
/// Provides keyword-matched context injection for LLM prompts.
struct TheaterContext {

    let projectDescription: String
    let techStack: String
    let keyConcepts: [String]
    let castMapping: String
    let voiceExamples: [VoiceExample]
    let fillers: [FillerEntry]
    let termExplainers: [TermEntry]
    let coldOpens: [ColdOpen]

    struct VoiceExample {
        let context: String  // what event this reacts to
        let dialogue: String // the 6-line dialogue
    }

    struct FillerEntry {
        let tags: Set<String>
        let dialogue: String
    }

    struct TermEntry {
        let term: String
        let keywords: [String]
        let plainEnglish: String  // jargon → plain English replacement for pre-stripping
        let dialogue: String
    }

    struct ColdOpen {
        let dialogue: String
    }

    // MARK: - Load from project path

    /// Try to load theater.md from a session's project directory.
    /// Falls back gracefully — returns nil if no file exists.
    static func load(fromSessionPath sessionPath: String) -> TheaterContext? {
        // Session path: ~/.claude/projects/-Users-name-Documents-MyProject/session.jsonl
        // We need to resolve back to the actual project path to find .claude/theater.md
        let sessionDir = (sessionPath as NSString).deletingLastPathComponent
        let projectDirName = (sessionDir as NSString).lastPathComponent

        // Decode Claude's path encoding: -Users-name-Documents-MyProject → /Users/name/Documents/MyProject
        debugLog("[TheaterContext] Resolving project path from dir: \(projectDirName)")
        let projectPath = resolveProjectPath(from: projectDirName)
        guard let projectPath else {
            debugLog("[TheaterContext] Could not resolve project path from: \(projectDirName)")
            return nil
        }
        debugLog("[TheaterContext] Resolved to: \(projectPath)")

        let theaterPath = projectPath + "/.claude/theater.md"
        debugLog("[TheaterContext] Checking: \(theaterPath)")
        guard FileManager.default.fileExists(atPath: theaterPath) else {
            debugLog("[TheaterContext] No theater.md at \(theaterPath)")
            return nil
        }
        debugLog("[TheaterContext] File exists, reading...")

        // macOS TCC blocks GUI apps from reading ~/Documents without user permission.
        // The /create-theater skill copies theater.md to ~/.siliconvalley/ as a workaround.
        // Try the TCC-free cache first, fall back to project path.
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".siliconvalley").appendingPathComponent("theater_cache")
        let projectName = (projectPath as NSString).lastPathComponent
        let cachedPath = cacheDir.appendingPathComponent(projectName + "_theater.md").path

        let content: String
        if let cached = try? String(contentsOfFile: cachedPath, encoding: .utf8) {
            content = cached
            debugLog("[TheaterContext] Read \(content.count) chars from cache: \(cachedPath)")
        } else if let direct = try? String(contentsOfFile: theaterPath, encoding: .utf8) {
            content = direct
            debugLog("[TheaterContext] Read \(content.count) chars directly from: \(theaterPath)")
            // Cache it for next time
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? content.write(toFile: cachedPath, atomically: true, encoding: .utf8)
        } else {
            debugLog("[TheaterContext] Could not read theater.md (TCC blocked or unreadable)")
            return nil
        }

        debugLog("[TheaterContext] Loaded theater.md (\(content.count) chars) from \(projectPath)")
        return parse(content)
    }

    /// Resolve Claude's encoded project directory name back to a filesystem path.
    private static func resolveProjectPath(from encoded: String) -> String? {
        // Claude encodes "/Users/name/Documents/My Project" as "-Users-name-Documents-My-Project"
        let stripped = encoded.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !stripped.isEmpty else { return nil }

        let parts = stripped.components(separatedBy: "-").filter { !$0.isEmpty }
        let fm = FileManager.default
        var resolved = ""

        var i = 0
        while i < parts.count {
            var matched = false
            for len in stride(from: parts.count - i, through: 1, by: -1) {
                let slice = parts[i..<(i + len)]
                let withDashes = resolved + "/" + slice.joined(separator: "-")
                if fm.fileExists(atPath: withDashes) {
                    resolved = withDashes
                    i += len
                    matched = true
                    break
                }
                if len > 1 {
                    let withSpaces = resolved + "/" + slice.joined(separator: " ")
                    if fm.fileExists(atPath: withSpaces) {
                        resolved = withSpaces
                        i += len
                        matched = true
                        break
                    }
                }
            }
            if !matched {
                resolved += "/" + parts[i]
                i += 1
            }
        }

        return fm.fileExists(atPath: resolved) ? resolved : nil
    }

    // MARK: - Parse theater.md

    private static func parse(_ content: String) -> TheaterContext {
        let sections = splitSections(content)

        let project = sections["Project"] ?? ""
        let techStack = sections["Tech Stack"] ?? ""
        let cast = sections["Cast"] ?? ""

        // Parse key concepts as bullet points
        let conceptsRaw = sections["Key Concepts"] ?? ""
        let concepts = conceptsRaw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("-") || $0.hasPrefix("*") }
            .map { String($0.dropFirst().trimmingCharacters(in: .whitespaces)) }
            .map { line in
                // Extract just the bold term name if present: **Term** — description
                if let dashRange = line.range(of: "—") {
                    return String(line[..<dashRange.lowerBound])
                        .replacingOccurrences(of: "**", with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
                return line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            }

        // Parse voice examples
        let voiceExamples = parseNumberedSubsections(sections["Voice Examples"] ?? "").map { sub in
            let context = extractComment(from: sub, tag: "Context")
            let dialogue = stripComments(sub)
            return VoiceExample(context: context, dialogue: dialogue)
        }

        // Parse fillers
        let fillers = parseNumberedSubsections(sections["Fillers"] ?? "").map { sub in
            let tagsStr = extractComment(from: sub, tag: "Tags")
            let tags = Set(tagsStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            let dialogue = stripComments(sub)
            return FillerEntry(tags: tags, dialogue: dialogue)
        }

        // Parse term explainers
        let termExplainers = parseNamedSubsections(sections["Term Explainers"] ?? "").map { (name, sub) in
            let kwStr = extractComment(from: sub, tag: "Keywords")
            let keywords = kwStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let plain = extractComment(from: sub, tag: "Plain")
            let dialogue = stripComments(sub)
            return TermEntry(term: name, keywords: keywords, plainEnglish: plain, dialogue: dialogue)
        }

        // Parse cold opens
        let coldOpens = parseNumberedSubsections(sections["Cold Opens"] ?? "").map { sub in
            ColdOpen(dialogue: stripComments(sub))
        }

        return TheaterContext(
            projectDescription: project.trimmingCharacters(in: .whitespacesAndNewlines),
            techStack: techStack.trimmingCharacters(in: .whitespacesAndNewlines),
            keyConcepts: concepts,
            castMapping: cast.trimmingCharacters(in: .whitespacesAndNewlines),
            voiceExamples: voiceExamples,
            fillers: fillers,
            termExplainers: termExplainers,
            coldOpens: coldOpens
        )
    }

    /// Split markdown by ## headers into a dictionary
    private static func splitSections(_ content: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentKey: String?
        var currentLines: [String] = []

        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                if let key = currentKey {
                    sections[key] = currentLines.joined(separator: "\n")
                }
                currentKey = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        if let key = currentKey {
            sections[key] = currentLines.joined(separator: "\n")
        }
        return sections
    }

    /// Split a section into numbered subsections (### Filler 1, ### Filler 2, etc.)
    private static func parseNumberedSubsections(_ content: String) -> [String] {
        var subs: [String] = []
        var current: [String] = []

        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("### ") {
                if !current.isEmpty { subs.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { subs.append(current.joined(separator: "\n")) }
        return subs
    }

    /// Split into named subsections: ### TermName → ("TermName", content)
    private static func parseNamedSubsections(_ content: String) -> [(String, String)] {
        var subs: [(String, String)] = []
        var currentName: String?
        var current: [String] = []

        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("### ") {
                if let name = currentName {
                    subs.append((name, current.joined(separator: "\n")))
                }
                currentName = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                current = []
            } else {
                current.append(line)
            }
        }
        if let name = currentName {
            subs.append((name, current.joined(separator: "\n")))
        }
        return subs
    }

    /// Extract <!-- Tag: value --> from a subsection
    private static func extractComment(from text: String, tag: String) -> String {
        let pattern = "<!--\\s*\(tag):\\s*(.+?)\\s*-->"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return "" }
        return String(text[range])
    }

    /// Strip HTML comments from dialogue text
    private static func stripComments(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - RAG: keyword-matched context for prompts

    /// Pick the most relevant voice example based on event keywords.
    /// Returns the best-matching example dialogue, or nil if no good match.
    /// A random fallback would poison the prompt — e.g. a "build failed" example
    /// when the actual build succeeded causes the model to mimic failure dialogue.
    func bestExample(forEvents eventSummary: String) -> String? {
        guard !voiceExamples.isEmpty else { return nil }

        let lower = eventSummary.lowercased()

        // Score each example by keyword overlap with its context description
        var bestScore = 0
        var bestExample: VoiceExample?

        for example in voiceExamples {
            let contextWords = example.context.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count > 3 }
            let score = contextWords.filter { lower.contains($0) }.count
            if score > bestScore {
                bestScore = score
                bestExample = example
            }
        }

        // Only use if we got a meaningful match (2+ keyword overlaps).
        // No match → return nil, let the theme's hardcoded example be used instead.
        // A random example would mislead the model (e.g. failure example on success events).
        guard bestScore >= 2, let chosen = bestExample else { return nil }
        return chosen.dialogue
    }

    /// Build a short project context string for injection into prompts.
    /// Keeps it under ~200 chars to not overwhelm the small LLM.
    func projectContext() -> String {
        var ctx = projectDescription.prefix(150)
        if !techStack.isEmpty {
            ctx += ". Tech: \(techStack.prefix(60))"
        }
        return String(ctx)
    }

    /// Find a matching filler from theater.md based on context tags.
    func matchedFiller(forTags tags: Set<String>) -> FillerEntry? {
        fillers.first { entry in
            !entry.tags.intersection(tags).isEmpty
        }
    }

    /// Find a term explainer matching keywords in event text.
    func matchedTermExplainer(forText text: String) -> TermEntry? {
        let lower = text.lowercased()
        return termExplainers.first { entry in
            entry.keywords.contains { lower.contains($0) }
        }
    }

    /// Build a jargon → plain English dictionary from all term explainers.
    /// Used by the pre-stripper to replace technical terms before they hit the LLM.
    /// Each term's keywords become lookup keys, and its `plainEnglish` is the replacement.
    func jargonMap() -> [(term: String, plain: String)] {
        var map: [(term: String, plain: String)] = []
        for entry in termExplainers {
            guard !entry.plainEnglish.isEmpty else { continue }
            // The term name itself is a jargon word
            map.append((term: entry.term, plain: entry.plainEnglish))
            // Each keyword is also a potential jargon match
            for kw in entry.keywords where kw != entry.term.lowercased() && kw.count > 3 {
                map.append((term: kw, plain: entry.plainEnglish))
            }
        }
        // Sort by term length descending so longer matches replace first
        // ("voice cloning" before "voice", "dispatch source" before "dispatch")
        return map.sorted { $0.term.count > $1.term.count }
    }
}
