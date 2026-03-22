import Foundation
import SwiftUI

// MARK: - Debug Logger

func debugLog(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)\n"
    print(line, terminator: "")
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".siliconvalley")
    let logPath = logDir.appendingPathComponent("debug.log")
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

    // Rotate if log exceeds 5 MB
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath.path),
       let size = attrs[.size] as? UInt64, size > 5_000_000 {
        let oldPath = logDir.appendingPathComponent("debug.old.log")
        try? FileManager.default.removeItem(at: oldPath)
        try? FileManager.default.moveItem(at: logPath, to: oldPath)
    }

    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath.path) {
            if let fh = try? FileHandle(forWritingTo: logPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: logPath)
        }
    }
}

// MARK: - TheaterEngine

/// Central orchestrator: watches Claude Code -> buffers events -> generates dialogue -> plays it.
@MainActor
@Observable
final class TheaterEngine {

    // MARK: - Published State

    private(set) var phase: Phase = .idle
    private(set) var dialogueHistory: [DialogueLine] = []
    private(set) var currentLine: DialogueLine?
    private(set) var currentSpeaker: Int?
    private(set) var eventLog: [SessionEvent] = []
    private(set) var ollamaAvailable = false
    private(set) var llmAvailable = false
    private(set) var ttsReady = false
    private(set) var ttsStarting = false
    private(set) var error: String?
    private(set) var errorTime: Date?
    private(set) var isPaused = false

    /// Tracks the last dialogue snippet per session path (for room list display).
    private(set) var roomSnippets: [String: String] = [:]

    /// The latest user message, summarized for display in the "Richard" tile.
    private(set) var latestUserMessage: String?
    /// Timestamp of the latest user message (for fade-out timing).
    private(set) var latestUserMessageTime: Date?

    /// Whether the app needs initial setup (LLM provider not configured).
    var needsSetup: Bool {
        switch config.llmProvider {
        case .groq:  return config.groqApiKey.isEmpty
        case .ollama: return !llmAvailable
        }
    }

    var config: TheaterConfig {
        didSet {
            audioPlayer.masterVolume = config.masterVolume
            ConfigStore.shared.save(config)
        }
    }

    enum Phase: String {
        case idle = "Idle"
        case watching = "Watching"
        case buffering = "Buffering events..."
        case generating = "Generating dialogue..."
        case synthesizing = "Synthesizing speech..."
        case playing = "Playing"
    }

    // MARK: - Private

    let watcher = SessionWatcher()
    private let audioPlayer = AudioPlayer()
    private let sidecarTTSManager = TTSManager()
    private let cloudTTSManager = CloudTTSManager()
    private let fishTTSManager = FishAudioTTSManager()
    private var dialogueGenerator: DialogueGenerator
    private var eventBuffer: [SessionEvent] = []
    private var bufferStartTime: Date?
    private var watchTask: Task<Void, Never>?
    private var bufferTask: Task<Void, Never>?
    private var generateTask: Task<Void, Never>?
    private var isRunning = false
    private var isGenerating = false
    private var coldOpenTask: Task<Void, Never>?
    private var coldOpenPlayed = false
    private var introPool: [[(Int, String)]] = [] // consume-and-discard intro variations
    private var voiceCache: [String: Data] = [:]       // text+voice hash → WAV data (persists in memory)
    private let fillerPool = DynamicFillerPool()       // Dynamic filler pool with consume-and-replenish
    private(set) var theaterContext: TheaterContext?    // Project-specific context from .claude/theater.md

    // MARK: - Init

    init() {
        let loadedConfig = ConfigStore.shared.load()
        let client = Self.makeLLMClient(config: loadedConfig)
        self.config = loadedConfig
        self.dialogueGenerator = DialogueGenerator(client: client)
        self.audioPlayer.masterVolume = loadedConfig.masterVolume
    }

    private static func makeLLMClient(config: TheaterConfig) -> any LLMClient {
        switch config.llmProvider {
        case .groq:
            return GroqClient(apiKey: config.groqApiKey, model: config.groqModel)
        case .ollama:
            return OllamaClient(baseURL: config.ollamaURL, model: config.ollamaModel)
        }
    }

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        error = nil

        // Recreate LLM client in case config changed
        dialogueGenerator = DialogueGenerator(client: Self.makeLLMClient(config: config))

        // Seed filler pool with static content for instant playback
        fillerPool.seed(themeId: config.activeThemeId)

        phase = .watching
        debugLog("[Theater] Started (\(config.llmProvider.rawValue) / \(config.ttsProvider.rawValue))")

        // Check LLM + TTS availability, then play cold open
        coldOpenPlayed = false
        Task {
            llmAvailable = await dialogueGenerator.isAvailable()
            ollamaAvailable = llmAvailable

            if llmAvailable {
                debugLog("[Theater] LLM connected (\(config.llmProvider.rawValue))")
            } else {
                switch config.llmProvider {
                case .groq:
                    setError("Groq API not reachable. Check your API key at console.groq.com")
                case .ollama:
                    setError("Ollama not reachable at \(config.ollamaURL). Run 'ollama serve' first.")
                }
            }

            await setupTTS()

            // Play cold open banter while waiting for real events
            if ttsReady && !coldOpenPlayed {
                coldOpenPlayed = true
                coldOpenTask = Task { @MainActor [weak self] in
                    await self?.playColdOpen()
                }
            }
        }

        // Start watching JSONL files
        watchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.watcher.watch()
            debugLog("[Theater] Watcher started. Session file: \(self.watcher.currentSessionFile ?? "searching...")")

            // Load theater.md after watcher finds a session
            if let sessionPath = self.watcher.currentSessionFile, self.theaterContext == nil {
                self.theaterContext = TheaterContext.load(fromSessionPath: sessionPath)
            }

            for await event in stream {
                guard self.isRunning else { break }
                debugLog("[Theater] Event: \(event.type.rawValue) - \(event.summary.prefix(80))")
                self.handleEvent(event)
            }
            debugLog("[Theater] Watch stream ended")
        }
    }

    func stop() {
        isRunning = false
        isPaused = false
        watchTask?.cancel()
        watchTask = nil
        bufferTask?.cancel()
        bufferTask = nil
        coldOpenTask?.cancel()
        coldOpenTask = nil
        fillerPool.cancelAll()
        watcher.stop()
        audioPlayer.stopAll()
        if !isGenerating {
            phase = .idle
        }
        eventBuffer.removeAll()
        currentLine = nil
        currentSpeaker = nil
        debugLog("[Theater] Stopped")
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        audioPlayer.stopAll()
        fillerPool.pauseReplenishing()
        debugLog("[Theater] Paused")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        debugLog("[Theater] Resumed")
        // Re-trigger generation if events accumulated while paused
        if !eventBuffer.isEmpty {
            startBufferTimer()
        } else {
            startFillerReplenishment()
        }
    }

    func togglePause() {
        if isPaused { resume() } else { pause() }
    }

    func skipCurrentLine() {
        audioPlayer.stopAll()
    }

    func clearHistory() {
        dialogueHistory.removeAll()
        eventLog.removeAll()
    }

    // MARK: - Error Handling

    private func setError(_ message: String) {
        error = message
        errorTime = Date()
        debugLog("[Theater] ERROR: \(message)")
        // Auto-clear errors after 10 seconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.errorTime != nil else { return }
            if let errorTime = self.errorTime, Date().timeIntervalSince(errorTime) >= 9 {
                self.error = nil
                self.errorTime = nil
            }
        }
    }

    /// Inject fake events and trigger generation immediately (for testing).
    func demo() {
        guard !isGenerating else { return }
        let fakeEvents = [
            SessionEvent(type: .userMessage, summary: "User: Refactor auth middleware to JWT", detail: "User asked: Can you refactor the authentication middleware to use JWT tokens instead of session cookies? The current implementation is too slow.", timestamp: Date(), sessionId: "demo"),
            SessionEvent(type: .assistantText, summary: "Claude: I'll refactor the auth middleware", detail: "Claude explains: I'll replace the session-based auth with JWT tokens. This means updating the middleware to validate Bearer tokens, adding a jwt.verify() call, and removing the session store dependency.", timestamp: Date(), sessionId: "demo"),
            SessionEvent(type: .toolUse, summary: "Tool: Read — auth.swift", detail: "Reading file auth.swift — found SessionMiddleware class with cookieStore.get(sessionId) pattern, 142 lines", timestamp: Date(), sessionId: "demo"),
            SessionEvent(type: .toolUse, summary: "Tool: Edit — auth.swift", detail: "Editing auth.swift — replacing \"let session = cookieStore.get(req.sessionId)\" with \"let payload = try jwt.verify(req.bearerToken, using: .hs256(key: signingKey))\"", timestamp: Date(), sessionId: "demo"),
            SessionEvent(type: .toolUse, summary: "Tool: Bash — swift test", detail: "Running command: swift test --filter AuthTests — testing JWT middleware changes", timestamp: Date(), sessionId: "demo"),
            SessionEvent(type: .toolResult, summary: "Result: All 12 tests passed", detail: "Output: Test Suite 'AuthTests' passed at 2024-01-15. Executed 12 tests, with 0 failures in 0.847 seconds. testJWTValidation passed, testExpiredToken passed, testMissingBearer passed.", timestamp: Date(), sessionId: "demo"),
        ]
        for e in fakeEvents { eventLog.append(e) }
        debugLog("[Theater] Demo mode: injecting \(fakeEvents.count) fake events")

        isGenerating = true
        generateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateAndPlay(events: fakeEvents)
            self.isGenerating = false
        }
    }

    /// Assign a theme to a specific session/room.
    func setRoomTheme(_ themeId: String, forSession sessionPath: String) {
        config.setTheme(themeId, forSession: sessionPath)
        // If this is the currently active session, also apply the theme globally
        if watcher.currentSessionFile == sessionPath {
            if let theme = ThemeStore.shared.allThemes().first(where: { $0.id == themeId }) {
                config.applyTheme(theme)
            }
            // Re-seed filler pool with new theme's content
            fillerPool.resetForTheme(themeId: themeId)
        }
        debugLog("[Theater] Set room theme: \(themeId) for \(sessionPath.suffix(40))")
    }

    /// Cycle to the next available theme for a session/room.
    func cycleRoomTheme(forSession sessionPath: String) {
        let themes = ThemeStore.shared.allThemes()
        guard !themes.isEmpty else { return }
        let currentId = config.themeId(forSession: sessionPath)
        let currentIdx = themes.firstIndex(where: { $0.id == currentId }) ?? 0
        let nextIdx = (currentIdx + 1) % themes.count
        setRoomTheme(themes[nextIdx].id, forSession: sessionPath)
    }

    /// Switch the active room: pin to this session and apply its theme.
    func selectRoom(_ sessionPath: String) {
        watcher.pinSession(sessionPath)
        latestUserMessage = nil
        latestUserMessageTime = nil
        currentLine = nil
        currentSpeaker = nil
        // Reload theater context for the new room's project
        theaterContext = TheaterContext.load(fromSessionPath: sessionPath)
        let themeId = config.themeId(forSession: sessionPath)
        if let theme = ThemeStore.shared.allThemes().first(where: { $0.id == themeId }) {
            config.applyTheme(theme)
        }
        debugLog("[Theater] Selected room: \(sessionPath.suffix(40)) with theme \(themeId)")
    }

    func restartTTS() {
        Task {
            debugLog("[Theater] Restarting TTS...")
            await setupTTS()
        }
    }

    private func setupTTS() async {
        ttsStarting = true
        ttsReady = false

        switch config.ttsProvider {
        case .fishAudio:
            fishTTSManager.configure(apiKey: config.fishAudioApiKey)
            let healthy = await fishTTSManager.checkHealth()
            if healthy {
                let voiceIDs = config.characters.map(\.voiceID)
                await fishTTSManager.warmUpVoices(voiceIDs: voiceIDs)
                ttsReady = fishTTSManager.isReady
                debugLog("[Theater] TTS ready: Fish Audio (zero-shot cloning)")
            } else {
                debugLog("[Theater] Fish Audio not available. Check API key.")
            }

        case .cartesia:
            cloudTTSManager.configure(apiKey: config.cartesiaApiKey)
            let healthy = await cloudTTSManager.checkHealth()
            if healthy {
                let voiceIDs = config.characters.map(\.voiceID)
                await cloudTTSManager.warmUpVoices(voiceIDs: voiceIDs)
                ttsReady = cloudTTSManager.isReady
                debugLog("[Theater] TTS ready: Cartesia Cloud")
            } else {
                debugLog("[Theater] Cartesia not available. Check API key.")
            }

        case .sidecar:
            await sidecarTTSManager.startSidecar(engine: "pocket")
            ttsReady = sidecarTTSManager.isReady
            if ttsReady {
                debugLog("[Theater] TTS ready: Pocket TTS (local)")
            } else {
                debugLog("[Theater] Pocket TTS sidecar not available")
            }

        case .kokoroSidecar:
            await sidecarTTSManager.startSidecar(engine: "kokoro")
            ttsReady = sidecarTTSManager.isReady
            if ttsReady {
                debugLog("[Theater] TTS ready: Kokoro (local)")
            } else {
                debugLog("[Theater] Kokoro sidecar not available")
            }

        case .disabled:
            debugLog("[Theater] TTS disabled, text-only mode")
        }

        ttsStarting = false
    }

    /// Recent event details for context-aware filler selection.
    private var recentEventDetails: [String] {
        let recent = eventLog.suffix(10)
        return recent.map(\.detail)
    }

    // MARK: - User Message Summary

    /// Summarize a user message into a short "what Richard said" blurb for the UI tile.
    /// Keeps it short and natural — like a Zoom call caption.
    private func summarizeUserMessage(_ detail: String) -> String {
        // Strip "User asked: " or similar prefixes
        var text = detail
        for prefix in ["User asked: ", "User said: ", "User: "] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }

        // Truncate to ~80 chars at a word boundary
        if text.count > 80 {
            let truncated = text.prefix(80)
            if let lastSpace = truncated.lastIndex(of: " ") {
                text = String(truncated[truncated.startIndex..<lastSpace]) + "..."
            } else {
                text = String(truncated) + "..."
            }
        }

        return text
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: SessionEvent) {
        eventLog.append(event)
        if eventLog.count > 200 { eventLog.removeFirst() }

        // Lazy-load theater context on first event if not loaded yet
        if theaterContext == nil, let sessionPath = watcher.currentSessionFile {
            theaterContext = TheaterContext.load(fromSessionPath: sessionPath)
        }

        // Capture user messages for the "Richard" tile
        if event.type == .userMessage {
            latestUserMessage = summarizeUserMessage(event.detail)
            latestUserMessageTime = Date()
        }

        // Pause filler replenishment — real events take priority
        fillerPool.pauseReplenishing()

        eventBuffer.append(event)

        if bufferStartTime == nil && !isGenerating && phase != .playing {
            bufferStartTime = Date()
            phase = .buffering
            debugLog("[Theater] Buffering started (\(Int(config.bufferDuration))s window)...")
            startBufferTimer()
        }
    }

    private func startBufferTimer() {
        bufferTask?.cancel()
        bufferTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.config.bufferDuration))
            guard !Task.isCancelled else { return }

            // If we've been buffering for a while without generating,
            // play fillers to fill the silence while we wait for more events
            if let start = self.bufferStartTime,
               Date().timeIntervalSince(start) > 4.0,
               self.phase == .buffering,
               !self.isGenerating {
                let _ = await self.playFillers()
            }

            self.triggerGeneration()
        }
    }

    private func triggerGeneration() {
        guard !isGenerating, !isPaused else { return }
        let events = eventBuffer
        eventBuffer.removeAll()
        bufferStartTime = nil
        guard !events.isEmpty else {
            phase = .watching
            return
        }

        isGenerating = true
        let eventsForTermDetect = events // capture for term detection
        generateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateAndPlay(events: eventsForTermDetect)
            self.isGenerating = false

            guard self.isRunning else {
                self.phase = .idle
                return
            }

            // Check for technical terms in the events — play contextual explainer from pool
            let allTerms = eventsForTermDetect.map { $0.detail }
            if let explainerSet = self.fillerPool.consumeTermExplainer(forTerms: allTerms) {
                debugLog("[Theater] Playing term-triggered explainer filler...")
                await self.playLines(explainerSet.lines)
            }

            // Detect novel terms not covered by existing explainers — generate in background
            let novelTerms = self.fillerPool.detectNovelTerms(fromEventDetails: allTerms)
            for term in novelTerms {
                self.fillerPool.generateTermExplainer(
                    term: term,
                    generator: self.dialogueGenerator,
                    config: self.config,
                    activeTheme: ThemeStore.shared.allThemes().first { $0.id == self.config.activeThemeId },
                    synthesize: { [weak self] text, voiceID, speed in
                        await self?.synthesizeCached(text: text, voiceID: voiceID, speed: speed)
                    }
                )
            }

            if !self.eventBuffer.isEmpty {
                self.bufferStartTime = Date()
                self.phase = .buffering
                debugLog("[Theater] New events arrived during generation, rebuffering...")
                self.startBufferTimer()
            } else {
                self.startFillerReplenishment()
            }
        }
    }

    /// Start background replenishment of the filler pool via LLM generation.
    private func startFillerReplenishment() {
        guard isRunning else { return }
        // Build context summary from recent events for relevant filler generation
        let contextSummary = recentEventDetails.suffix(5).joined(separator: ". ")
        fillerPool.startReplenishing(
            generator: dialogueGenerator,
            config: config,
            activeTheme: ThemeStore.shared.allThemes().first { $0.id == config.activeThemeId },
            recentContext: contextSummary.isEmpty ? nil : String(contextSummary.prefix(300)),
            synthesize: { [weak self] text, voiceID, speed in
                await self?.synthesizeCached(text: text, voiceID: voiceID, speed: speed)
            }
        )
    }

    /// Play the next filler set from the pool. Returns true if fillers were played.
    private func playFillers() async -> Bool {
        guard let set = fillerPool.consumeNext(contextHints: recentEventDetails) else { return false }

        debugLog("[Theater] Playing filler set (\(set.source), \(set.lines.count) lines, pool: \(fillerPool.poolStatus))")
        await playLines(set.lines)
        return true
    }

    /// Synthesize with voice cache — checks disk cache, then memory, then synthesizes.
    /// Persists to disk so fillers survive app restarts. Includes 15s timeout for TTS calls.
    private func synthesizeCached(text: String, voiceID: String, speed: Float) async -> Data? {
        let cacheKey = "\(voiceID):\(text)"
        let diskKey = cacheKey.data(using: .utf8)!.base64EncodedString()
            .prefix(40).replacingOccurrences(of: "/", with: "_")
        let cacheDir = NSHomeDirectory() + "/.siliconvalley/voice_cache"
        let diskPath = cacheDir + "/\(diskKey).wav"

        // Ensure cache directory exists
        try? FileManager.default.createDirectory(
            atPath: cacheDir, withIntermediateDirectories: true)

        // Check memory cache first
        if let cached = voiceCache[cacheKey] { return cached }

        // Check disk cache
        if let diskData = try? Data(contentsOf: URL(fileURLWithPath: diskPath)) {
            voiceCache[cacheKey] = diskData
            debugLog("[VoiceCache] Disk hit: \(text.prefix(30))...")
            return diskData
        }

        // Synthesize fresh with 15s timeout to prevent hangs
        let provider = config.ttsProvider
        let audio: Data? = await withTaskGroup(of: Data?.self) { group in
            group.addTask { @MainActor [self] in
                switch provider {
                case .sidecar, .kokoroSidecar:
                    return await self.sidecarTTSManager.synthesize(text: text, voiceID: voiceID, speed: speed)
                case .fishAudio:
                    return await self.fishTTSManager.synthesize(text: text, voiceID: voiceID, speed: speed)
                case .cartesia:
                    return await self.cloudTTSManager.synthesize(text: text, voiceID: voiceID, speed: speed)
                case .disabled:
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return nil // timeout sentinel
            }
            // Return whichever finishes first
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }

        if let audio {
            voiceCache[cacheKey] = audio
            try? audio.write(to: URL(fileURLWithPath: diskPath))
            debugLog("[VoiceCache] Cached to disk: \(text.prefix(30))...")

            // Keep memory cache bounded
            while voiceCache.count > 80 {
                if let oldest = voiceCache.keys.first {
                    voiceCache.removeValue(forKey: oldest)
                }
            }
            // Prune disk cache if too large (>200 files)
            pruneVoiceCacheIfNeeded(cacheDir: cacheDir)
        } else if provider != .disabled {
            debugLog("[VoiceCache] TTS timed out or failed for: \(text.prefix(30))...")
        }
        return audio
    }

    /// Prune disk voice cache to keep it under 200 files.
    private func pruneVoiceCacheIfNeeded(cacheDir: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: cacheDir) else { return }
        guard files.count > 200 else { return }
        let sorted = files.compactMap { name -> (String, Date)? in
            let path = cacheDir + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return (path, date)
        }.sorted { $0.1 < $1.1 }
        for (path, _) in sorted.prefix(sorted.count - 150) {
            try? fm.removeItem(atPath: path)
        }
        debugLog("[VoiceCache] Pruned \(sorted.count - 150) old cache files")
    }

    // MARK: - Cold Open

    /// Play pre-baked intro banter while waiting for real events.
    private func playColdOpen() async {
        guard isRunning, !isGenerating, !config.characters.isEmpty else { return }

        let char0 = config.characters[0]
        let char1 = config.characters.count > 1 ? config.characters[1] : config.characters[0]

        // Detect project name from session file using displayName resolver
        let projectHint: String
        if let path = watcher.currentSessionFile,
           let session = watcher.availableSessions.first(where: { $0.path == path }) {
            projectHint = session.displayName
        } else {
            projectHint = "some project"
        }

        // === PHASE 1: "Joining the call" intro (consume-and-discard, voice-cached) ===
        // Seed intro pool if empty
        if introPool.isEmpty {
            introPool = Self.makeIntroPool(projectHint: projectHint)
            introPool.shuffle()
            debugLog("[Theater] Seeded intro pool with \(introPool.count) variations")
        }

        // === PHASE 2: Fire off LLM with first user message during intro playback ===
        // Grab the first user message from the event buffer if available
        var contextGenTask: Task<[DialogueLine], Never>?
        let firstUserMsg = eventBuffer.first(where: { $0.type == .userMessage })?.detail
            .replacingOccurrences(of: "User asked: ", with: "")
            .replacingOccurrences(of: "User: ", with: "")

        if let msg = firstUserMsg, !msg.isEmpty {
            let gen = dialogueGenerator
            let cfg = config
            let theme = ThemeStore.shared.allThemes().first { $0.id == cfg.activeThemeId }
            let c0NameCtx = char0.name
            let c1NameCtx = char1.name
            let proj = projectHint

            contextGenTask = Task.detached {
                let prompt = """
                Write 6 lines. \(c0NameCtx) and \(c1NameCtx) discuss what the developer just asked them to work on. Explain what it means simply. Stay in character. Under 25 words each.

                The developer wants help with \(proj). They said: "\(String(msg.prefix(200)))"

                \(theme?.fewShotExample ?? "")

                \(c0NameCtx):
                \(c1NameCtx):
                \(c0NameCtx):
                \(c1NameCtx):
                \(c0NameCtx):
                \(c1NameCtx):
                """
                let names = cfg.characters.map(\.name)
                do {
                    let response = try await gen.client.generate(prompt: prompt, maxTokens: 350)
                    return DialogueParser.parse(response, names: names)
                } catch {
                    return []
                }
            }
            debugLog("[Theater] Fired context generation during intro: \(String(msg.prefix(60)))...")
        }

        // Consume one intro from the pool (never replayed)
        let chosen: [(Int, String)]
        if !introPool.isEmpty {
            chosen = introPool.removeFirst()
        } else {
            chosen = [(0, "Let's see what's happening with \(projectHint)."), (1, "Connecting now.")]
        }
        let coldLines = chosen.map { DialogueLine(characterIndex: $0.0, text: $0.1) }

        debugLog("[Theater] Playing intro (\(coldLines.count) lines)...")

        // Play intro lines (voice-cached for instant replay next time)
        await playLines(coldLines)

        // === PHASE 3: Play context discussion (Qwen result from during intro) ===
        if let task = contextGenTask {
            let contextLines = await task.value
            if !contextLines.isEmpty && isRunning && !isGenerating {
                debugLog("[Theater] Playing context discussion (\(contextLines.count) lines)...")
                await playLines(contextLines)
            } else if contextLines.isEmpty {
                debugLog("[Theater] Context generation returned empty — playing fillers")
                if let set = fillerPool.consumeNext(contextHints: recentEventDetails) {
                    await playLines(set.lines)
                }
            }
        } else {
            // No user message yet — play fillers while waiting
            if let set = fillerPool.consumeNext(contextHints: recentEventDetails) {
                debugLog("[Theater] No user message yet — playing filler banter...")
                await playLines(set.lines)
            }
        }

        // Start replenishing filler pool for future gaps
        startFillerReplenishment()

        currentLine = nil
        currentSpeaker = nil
        phase = isRunning ? .watching : .idle
        debugLog("[Theater] Intro sequence done")
    }

    /// Build the full intro pool — show-inspired variations that get consumed once each.
    private static func makeIntroPool(projectHint: String) -> [[(Int, String)]] {
        [
            [
                (0, "Looks like someone's working on \(projectHint). Let me pull up the session."),
                (1, "Of course they called us. Nobody calls when things are going well."),
                (0, "That's fair. How bad can it be?"),
                (1, "You say that every time. And every time it's worse."),
                (0, "I'll take that bet. Connecting now."),
                (1, "Okay I can see the code. Let's do this."),
            ],
            [
                (1, "We've got an incoming session. \(projectHint)."),
                (0, "Alright. What are they breaking this time."),
                (1, "Hey, maybe they're building something great."),
                (0, "In my experience, building and breaking are the same activity."),
                (1, "That's surprisingly philosophical for you."),
                (0, "I contain multitudes. And also several root kits. Connecting."),
            ],
            [
                (0, "New session. \(projectHint)."),
                (1, "Oh nice I've been curious what they'd do next."),
                (0, "Last time they spent an hour renaming variables."),
                (1, "Naming things IS one of the two hard problems in computer science."),
                (0, "The other being cache invalidation. And off by one errors."),
                (1, "That's three things. Anyway I'm in."),
            ],
            [
                (1, "You know what, I have a good feeling about this session."),
                (0, "That's because you have no pattern recognition. Every session is chaos."),
                (1, "I choose optimism. It's a lifestyle choice."),
                (0, "It's a coping mechanism. But sure. Let's connect to \(projectHint)."),
                (1, "See? We're already bonding over shared delusion."),
                (0, "That's not what bonding is."),
            ],
            [
                (0, "I was about to mass delete your config files but \(projectHint) just came in."),
                (1, "Wait what? Which config files?"),
                (0, "Relax. Your configs are safe. For now. Let's see what they need."),
                (1, "You can't just SAY things like that and move on."),
                (0, "I can and I did. Focus. Session's live."),
                (1, "Fine but we're revisiting this later."),
            ],
            [
                (1, "Another day another session. Who needs hobbies when you have \(projectHint)."),
                (0, "I have hobbies. Server maintenance. Network security. Destroying Dinesh's confidence."),
                (1, "Two of those are work and the third is just mean."),
                (0, "And yet I'm never bored. Connecting now."),
                (1, "One day you'll say something nice to me."),
                (0, "Don't hold your breath. Code's loading."),
            ],
            [
                (0, "Dinesh. Session alert."),
                (1, "Ooh what are they working on?"),
                (0, "\(projectHint). Based on the project name alone, I give it a thirty percent chance of being well-structured."),
                (1, "That's generous for you. You gave Richard's compression algorithm fifteen percent."),
                (0, "And I was right. It crashed the demo. Twice."),
                (1, "Okay fair point. Let's see what we're dealing with."),
            ],
            [
                (1, "I just made coffee and there's a session starting. Perfect timing."),
                (0, "Your coffee tastes like despair and hazelnut. But yes. \(projectHint) is up."),
                (1, "It's a COLD BREW. It's supposed to taste like that."),
                (0, "Sure it is. Let's connect before your coffee gets as cold as your code reviews."),
                (1, "My code reviews are THOROUGH not cold."),
                (0, "You approved seventeen PRs in twelve minutes last Thursday. Thorough."),
            ],
            [
                (0, "You know what Big Head would say right now? 'Wait what's a session.'"),
                (1, "Big Head got ten million dollars from Erlich for saying that exact sentence."),
                (0, "And he somehow turned that into a board seat. The man fails upward."),
                (1, "Meanwhile we're here. Working. On \(projectHint). Like professionals."),
                (0, "Professionals who are underpaid and over-caffeinated."),
                (1, "Don't call us out like that. Connecting."),
            ],
            [
                (1, "This is like that time Erlich pitched Aviato to a room full of investors."),
                (0, "You mean the time he mispronounced his own company name? Yes. Very inspiring."),
                (1, "He got funded though. Confidence matters."),
                (0, "He also got sued. Twice. Let's just open \(projectHint) and be competent about it."),
                (1, "Competence is our brand."),
                (0, "Your brand. Mine is controlled chaos."),
            ],
        ]
    }

    /// Play a list of dialogue lines with voice caching. Reusable helper.
    private func playLines(_ lines: [DialogueLine]) async {
        let useTTS = config.ttsEnabled && ttsReady && config.ttsProvider != .disabled

        for line in lines {
            guard isRunning, !isGenerating else {
                debugLog("[Theater] Playback interrupted")
                break
            }

            phase = .playing
            currentLine = line
            currentSpeaker = line.characterIndex
            dialogueHistory.append(line)
            if dialogueHistory.count > 500 { dialogueHistory.removeFirst() }

            if useTTS {
                let charIdx = min(line.characterIndex, config.characters.count - 1)
                let voiceID = config.characters[charIdx].voiceID
                let audio = await synthesizeCached(text: line.text, voiceID: voiceID, speed: config.ttsSpeed)

                if let audio {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        audioPlayer.playOnce(data: audio) { cont.resume() }
                    }
                } else {
                    try? await Task.sleep(for: .seconds(2.0))
                }
            } else {
                let readTime = max(2.0, Double(line.text.split(separator: " ").count) * 0.3)
                try? await Task.sleep(for: .seconds(readTime))
            }
        }
    }

    /// Send events to LLM for dialogue generation, then play with pipelined TTS.
    private func generateAndPlay(events: [SessionEvent]) async {
        phase = .generating
        debugLog("[Theater] Flushing \(events.count) events to \(config.llmProvider.rawValue)...")

        let generator = dialogueGenerator
        let cfg = config
        let activeTheme = ThemeStore.shared.allThemes().first { $0.id == config.activeThemeId }
        let lines: [DialogueLine]
        do {
            let ctx = theaterContext
            lines = try await Task.detached {
                try await generator.generate(events: events, config: cfg, activeTheme: activeTheme, theaterContext: ctx)
            }.value
            debugLog("[Theater] Generated \(lines.count) dialogue lines")
        } catch {
            self.error = "Generation failed: \(error.localizedDescription)"
            debugLog("[Theater] ERROR: \(self.error!)")
            phase = isRunning ? .watching : .idle
            return
        }

        guard !lines.isEmpty else {
            debugLog("[Theater] No lines generated, back to watching")
            phase = isRunning ? .watching : .idle
            return
        }

        for line in lines {
            let idx = min(line.characterIndex, config.characters.count - 1)
            debugLog("[Theater]   \(config.characters[idx].name): \(line.text.prefix(60))")
        }

        // Pipeline TTS: pre-fetch with concurrency limit, play in order
        let useTTS = config.ttsEnabled && ttsReady && config.ttsProvider != .disabled
        let speed = config.ttsSpeed
        let chars = config.characters
        let maxConcurrent = config.ttsProvider == .cartesia ? 2 : 4

        // Pre-synthesize all lines with concurrency control
        var audioResults: [Data?] = Array(repeating: nil, count: lines.count)
        if useTTS {
            phase = .synthesizing

            // Build (index, voiceID, text) work items
            var workItems: [(Int, String, String)] = []
            for (i, line) in lines.enumerated() {
                let charIdx = min(line.characterIndex, chars.count - 1)
                workItems.append((i, chars[charIdx].voiceID, line.text))
            }

            // Dispatch in batches of maxConcurrent
            var offset = 0
            while offset < workItems.count {
                let batch = Array(workItems[offset..<min(offset + maxConcurrent, workItems.count)])
                debugLog("[Theater] Pipeline: dispatching batch \(offset)..<\(offset + batch.count)...")

                let results = await withTaskGroup(of: (Int, Data?).self, returning: [(Int, Data?)].self) { group in
                    for (idx, voiceID, text) in batch {
                        let provider = config.ttsProvider
                        let fishTTS = fishTTSManager
                        let cloudTTS = cloudTTSManager
                        let sidecarTTS = sidecarTTSManager
                        group.addTask {
                            let data: Data?
                            switch provider {
                            case .fishAudio:      data = await fishTTS.synthesize(text: text, voiceID: voiceID, speed: speed)
                            case .cartesia:       data = await cloudTTS.synthesize(text: text, voiceID: voiceID, speed: speed)
                            case .sidecar:        data = await sidecarTTS.synthesize(text: text, voiceID: voiceID, speed: speed)
                            case .kokoroSidecar:  data = await sidecarTTS.synthesize(text: text, voiceID: voiceID, speed: speed)
                            case .disabled:       data = nil
                            }
                            return (idx, data)
                        }
                    }
                    var collected: [(Int, Data?)] = []
                    for await result in group { collected.append(result) }
                    return collected
                }

                for (idx, data) in results {
                    audioResults[idx] = data
                    debugLog("[Theater] Pipeline: line \(idx) → \(data != nil ? "\(data!.count / 1024)KB" : "failed")")
                }
                offset += maxConcurrent
            }
        }

        // Play in order
        for (i, line) in lines.enumerated() {
            phase = .playing
            currentLine = line
            currentSpeaker = line.characterIndex
            dialogueHistory.append(line)
            if dialogueHistory.count > 500 { dialogueHistory.removeFirst() }

            // Track snippet for the active room
            if let sessionFile = watcher.currentSessionFile {
                let idx = min(line.characterIndex, config.characters.count - 1)
                let name = config.characters[idx].name
                roomSnippets[sessionFile] = "\(name): \(line.text)"
            }

            if let audio = audioResults[i] {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    audioPlayer.playOnce(data: audio) {
                        cont.resume()
                    }
                }
            } else {
                let wordCount = line.text.split(separator: " ").count
                let readingTime = max(2.0, Double(wordCount) * 0.3)
                try? await Task.sleep(for: .seconds(readingTime))
            }
        }

        currentLine = nil
        currentSpeaker = nil
        phase = isRunning ? .watching : .idle
        debugLog("[Theater] Pipeline: all \(lines.count) lines done")
    }
}

// MARK: - Collection Safe Subscript

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
