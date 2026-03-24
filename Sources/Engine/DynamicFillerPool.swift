import Foundation

// MARK: - DynamicFillerPool

/// Manages a consume-and-replenish pool of filler dialogue sets.
/// Seeds from FillerLibrary (static), consumes sets on play (one-shot),
/// and generates new fillers via LLM during idle periods.
@MainActor
final class DynamicFillerPool {

    // MARK: - Configuration

    /// Target number of ready-to-play filler sets in the pool
    let targetPoolSize = 5

    // MARK: - Pool State

    /// Filler sets ready to play (voice-cached)
    private(set) var readyPool: [FillerSet] = []

    /// Term explainer entries (static + dynamic), consumed on play
    private var termExplainers: [TermExplainerEntry] = []

    /// Terms that have already been played or queued for generation (avoid duplicates).
    /// This set persists across seed/reset cycles to prevent re-triggering consumed terms.
    private var knownTerms: Set<String> = []

    /// Terms that have been consumed/played — never regenerate these, even after reset.
    private var consumedTerms: Set<String> = []

    /// Background replenishment task
    private var replenishTask: Task<Void, Never>?

    /// Whether replenishment is actively running
    private(set) var isReplenishing = false

    // MARK: - Seeding

    /// Load all static filler sets and term explainers as initial pool content.
    /// Called once at startup or when theme changes.
    func seed(themeId: String, theaterContext: TheaterContext? = nil) {
        // Load static filler sets (shuffled for variety)
        let staticSets = FillerLibrary.allSets(themeId: themeId)
        readyPool = staticSets

        // Load project-specific fillers from theater.md (higher priority — inserted at front)
        if let ctx = theaterContext {
            let projectFillers = ctx.fillers.compactMap { entry -> FillerSet? in
                let lines = parseFillerDialogue(entry.dialogue)
                guard !lines.isEmpty else { return nil }
                return FillerSet(lines: lines, source: .theaterMd, tags: entry.tags, isVoiceCached: false)
            }
            // Project-specific fillers go at the front — they're more relevant
            readyPool = projectFillers + readyPool
            debugLog("[FillerPool] Added \(projectFillers.count) project-specific fillers from theater.md")
        }

        // Load static term explainers
        termExplainers = FillerLibrary.allTermExplainerEntries()

        // Load project-specific term explainers from theater.md
        if let ctx = theaterContext {
            let projectTerms = ctx.termExplainers.compactMap { entry -> TermExplainerEntry? in
                let lines = parseFillerDialogue(entry.dialogue)
                guard !lines.isEmpty else { return nil }
                let set = FillerSet(lines: lines, source: .theaterMd, tags: Set(entry.keywords))
                return TermExplainerEntry(
                    canonicalTerm: entry.term.lowercased(),
                    keywords: entry.keywords,
                    fillerSet: set
                )
            }
            // Filter out terms already known (from static library)
            let newTerms = projectTerms.filter { !knownTerms.contains($0.canonicalTerm) }
            termExplainers.append(contentsOf: newTerms)
            debugLog("[FillerPool] Added \(newTerms.count) project-specific term explainers from theater.md")
        }

        knownTerms = Set(termExplainers.map(\.canonicalTerm))

        debugLog("[FillerPool] Seeded with \(readyPool.count) filler sets, \(termExplainers.count) term explainers")
    }

    /// Flush pool and re-seed for a new theme.
    func resetForTheme(themeId: String, theaterContext: TheaterContext? = nil) {
        cancelAll()
        readyPool.removeAll()
        termExplainers.removeAll()
        // Keep consumedTerms across resets — never replay consumed terms
        // Merge consumedTerms into knownTerms so they're also blocked from novel detection
        knownTerms = consumedTerms
        seed(themeId: themeId, theaterContext: theaterContext)
    }

    // MARK: - Consumption

    /// Pop the next filler set, preferring one that matches the current context.
    /// Pass recent event details to match fillers by tags. The set is permanently removed.
    func consumeNext(contextHints: [String] = []) -> FillerSet? {
        guard !readyPool.isEmpty else { return nil }

        // Derive context tags from recent event details
        let contextTags = Self.extractTags(from: contextHints)

        // Try to find a filler whose tags overlap with the context
        if !contextTags.isEmpty {
            // Score each set by tag overlap, pick the best match
            var bestIdx: Int?
            var bestScore = 0
            for (i, set) in readyPool.enumerated() {
                let overlap = set.tags.intersection(contextTags).count
                if overlap > bestScore {
                    bestScore = overlap
                    bestIdx = i
                }
            }
            if let idx = bestIdx, bestScore > 0 {
                debugLog("[FillerPool] Context match: tags=\(contextTags) matched \(readyPool[idx].tags)")
                return readyPool.remove(at: idx)
            }
        }

        // No context match — only pick fillers tagged as safe to play anytime.
        // Flip the logic: whitelist neutral tags instead of blacklisting situational ones.
        let neutralTags: Set<String> = [
            "coding", "edit", "file", "refactor",
            "git", "commit", "push",
            "search", "grep", "find", "glob",
        ]
        let neutralIdx = readyPool.firstIndex(where: { set in
            // A set is neutral if ANY of its tags are in the neutral whitelist
            !set.tags.intersection(neutralTags).isEmpty
        })
        if let idx = neutralIdx {
            return readyPool.remove(at: idx)
        }
        // If ALL remaining fillers are situational, return nothing rather than play the wrong one
        return nil
    }

    /// Extract context tags from event detail strings.
    private static func extractTags(from details: [String]) -> Set<String> {
        let text = details.joined(separator: " ").lowercased()
        var tags = Set<String>()

        let tagKeywords: [String: [String]] = [
            "git": ["git", "commit", "branch", "push", "pull", "checkout"],
            "merge": ["merge", "rebase", "conflict"],
            "deploy": ["deploy", "production", "ship", "release"],
            "refactor": ["refactor", "rename", "cleanup", "restructure", "reorganize"],
            "edit": ["edit", "editing", "write", "writing", "modify"],
            "file": ["read", "file", "open", "reading"],
            "search": ["search", "grep", "find", "glob", "pattern"],
            "server": ["server", "docker", "container", "port", "localhost"],
            "coding": ["function", "class", "method", "variable", "import", "module"],
            "infrastructure": ["config", "env", "yaml", "json", "settings"],
            "legacy": ["legacy", "deprecated", "old", "migrate", "upgrade"],
            "cleanup": ["clean", "remove", "delete", "unused", "dead code"],
        ]

        for (tag, keywords) in tagKeywords {
            if keywords.contains(where: { text.contains($0) }) {
                tags.insert(tag)
            }
        }

        // Sentiment-aware tags: distinguish success from failure
        let hasSuccess = text.contains("succeed") || text.contains("success") || text.contains("passed")
            || text.contains("no error") || text.contains("built:") || text.contains("built ")
            || text.contains("compiled") || text.contains("all passed") || text.contains("no failures")
        let hasFailure = text.contains("fail") || text.contains("error") || text.contains("crash")
            || text.contains("broken") || text.contains("exception") || text.contains("undefined")
            || text.contains("bug") || text.contains("wrong")

        // Build outcome
        if text.contains("build") || text.contains("compile") || text.contains("make") {
            if hasFailure && !hasSuccess {
                tags.insert("build-fail")
            } else if hasSuccess && !hasFailure {
                tags.insert("build-success")
                tags.insert("built")
            } else {
                tags.insert("build") // ambiguous — won't match build-fail or build-success
            }
        }

        // Test outcome
        if text.contains("test") || text.contains("spec") || text.contains("assert") {
            if hasSuccess && !hasFailure {
                tags.insert("test-pass")
                tags.insert("tests-passed")
                tags.insert("all-passed")
            } else if hasFailure && !hasSuccess {
                tags.insert("test-fail")
                tags.insert("test-failed")
            } else {
                tags.insert("test")
            }
        }

        // Debug/bug (only when something is actually broken)
        if hasFailure {
            tags.insert("debug")
            tags.insert("bug")
            tags.insert("investigate")
        }

        return tags
    }

    /// Parse a dialogue string (e.g. "David: Hello\nMoira: Hi") into DialogueLines.
    private func parseFillerDialogue(_ text: String) -> [DialogueLine] {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var result: [DialogueLine] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Try to parse "CharName: text" format
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let afterColon = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                guard !afterColon.isEmpty else { continue }
                // Character index: even lines = 0, odd lines = 1
                let charIdx = result.count % 2
                result.append(DialogueLine(characterIndex: charIdx, text: afterColon))
            }
        }
        return result
    }

    /// Find and consume a term explainer matching any detected keywords.
    /// Returns nil if no match or term already played.
    func consumeTermExplainer(forTerms terms: [String]) -> FillerSet? {
        let lower = terms.joined(separator: " ").lowercased()

        // Check static + dynamic term explainers
        if let idx = termExplainers.firstIndex(where: { entry in
            !consumedTerms.contains(entry.canonicalTerm) &&
            entry.keywords.contains(where: { lower.contains($0) })
        }) {
            let entry = termExplainers.remove(at: idx)
            consumedTerms.insert(entry.canonicalTerm)
            knownTerms.insert(entry.canonicalTerm)
            debugLog("[FillerPool] Consumed term explainer: '\(entry.canonicalTerm)' (permanently marked)")
            return entry.fillerSet
        }
        return nil
    }

    /// Detect novel technical terms in event text that we don't have explainers for.
    /// Returns terms that should be generated dynamically.
    func detectNovelTerms(fromEventDetails details: [String]) -> [String] {
        let lower = details.joined(separator: " ").lowercased()
        var novel: [String] = []
        for (term, keywords) in FillerLibrary.extendedTermKeywords {
            guard !knownTerms.contains(term), !consumedTerms.contains(term) else { continue }
            if keywords.contains(where: { lower.contains($0) }) {
                novel.append(term)
                knownTerms.insert(term)  // mark as known to avoid re-queuing
            }
        }
        return novel
    }

    // MARK: - Replenishment

    typealias SynthesizeFn = @MainActor (String, String, Float) async -> Data?

    /// Start background replenishment loop. Generates new fillers via LLM
    /// and pre-synthesizes TTS audio until pool reaches target size.
    /// Pass recentContext to generate contextually relevant fillers.
    func startReplenishing(
        generator: DialogueGenerator,
        config: TheaterConfig,
        activeTheme: CharacterTheme?,
        recentContext: String? = nil,
        synthesize: @escaping SynthesizeFn
    ) {
        guard !isReplenishing else { return }
        guard readyPool.count < targetPoolSize else {
            debugLog("[FillerPool] Pool full (\(readyPool.count)/\(targetPoolSize)), skipping replenishment")
            return
        }

        isReplenishing = true
        replenishTask?.cancel()
        replenishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isReplenishing = false }

            var consecutiveFailures = 0

            while !Task.isCancelled && self.readyPool.count < self.targetPoolSize {
                debugLog("[FillerPool] Replenishing... (\(self.readyPool.count)/\(self.targetPoolSize))")

                // Check LLM availability
                guard await generator.isAvailable() else {
                    debugLog("[FillerPool] LLM unavailable, stopping replenishment")
                    break
                }

                do {
                    let lines = try await generator.generateFiller(config: config, activeTheme: activeTheme, recentContext: recentContext)
                    guard !lines.isEmpty, !Task.isCancelled else { continue }

                    var set = FillerSet(lines: lines, source: .dynamic)

                    for line in lines {
                        guard !Task.isCancelled else { break }
                        let charIdx = min(line.characterIndex, config.characters.count - 1)
                        let voiceID = config.characters[charIdx].voiceID
                        let _ = await synthesize(line.text, voiceID, config.ttsSpeed)
                    }

                    guard !Task.isCancelled else { break }
                    set.isVoiceCached = true
                    self.readyPool.append(set)
                    consecutiveFailures = 0
                    debugLog("[FillerPool] Generated + cached dynamic filler set (\(self.readyPool.count)/\(self.targetPoolSize))")
                } catch {
                    consecutiveFailures += 1
                    debugLog("[FillerPool] Filler generation failed (\(consecutiveFailures)x): \(error.localizedDescription)")
                    // Exponential backoff: 4s, 8s, 16s, max 30s
                    if consecutiveFailures >= 3 {
                        debugLog("[FillerPool] Too many failures, stopping replenishment")
                        break
                    }
                }

                // Pause between generations (longer after failures)
                guard !Task.isCancelled else { break }
                let delay = consecutiveFailures > 0
                    ? UInt64(min(30, 4 * (1 << (consecutiveFailures - 1)))) * 1_000_000_000
                    : 3_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }

            debugLog("[FillerPool] Replenishment done. Pool: \(self.readyPool.count) ready")
        }
    }

    /// Generate a term explainer for a novel technical term via LLM.
    func generateTermExplainer(
        term: String,
        generator: DialogueGenerator,
        config: TheaterConfig,
        activeTheme: CharacterTheme?,
        synthesize: @escaping SynthesizeFn
    ) {
        // Fire-and-forget background task
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let lines = try await generator.generateTermExplainer(
                    term: term, config: config, activeTheme: activeTheme
                )
                guard !lines.isEmpty else { return }

                var set = FillerSet(lines: lines, source: .dynamic)

                // Pre-synthesize
                for line in lines {
                    let charIdx = min(line.characterIndex, config.characters.count - 1)
                    let voiceID = config.characters[charIdx].voiceID
                    let _ = await synthesize(line.text, voiceID, config.ttsSpeed)
                }
                set.isVoiceCached = true

                let keywords = FillerLibrary.extendedTermKeywords[term] ?? [term]
                let entry = TermExplainerEntry(
                    canonicalTerm: term,
                    keywords: keywords,
                    fillerSet: set
                )
                self.termExplainers.append(entry)
                debugLog("[FillerPool] Generated dynamic term explainer for '\(term)'")
            } catch {
                debugLog("[FillerPool] Term explainer generation failed for '\(term)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Lifecycle

    /// Pause replenishment (called when real events arrive and take priority).
    func pauseReplenishing() {
        replenishTask?.cancel()
        replenishTask = nil
        isReplenishing = false
    }

    /// Cancel all background work.
    func cancelAll() {
        replenishTask?.cancel()
        replenishTask = nil
        isReplenishing = false
    }

    // MARK: - Debug

    var poolStatus: String {
        "ready=\(readyPool.count) terms=\(termExplainers.count)"
    }
}
