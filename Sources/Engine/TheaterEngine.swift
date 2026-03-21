import Foundation
import SwiftUI

// MARK: - Debug Logger

func debugLog(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)\n"
    print(line, terminator: "")
    let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".siliconvalley")
        .appendingPathComponent("debug.log")
    try? FileManager.default.createDirectory(
        at: logPath.deletingLastPathComponent(), withIntermediateDirectories: true)
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

    /// Tracks the last dialogue snippet per session path (for room list display).
    private(set) var roomSnippets: [String: String] = [:]

    var config: TheaterConfig {
        didSet { ConfigStore.shared.save(config) }
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
    private var lastColdOpenIndex: Int = -1
    private var fillerTask: Task<Void, Never>?
    private var fillerQueue: [DialogueLine] = []       // Pre-generated filler lines ready to play
    private var fillerAudioCache: [String: Data] = [:] // text hash → WAV data
    private var voiceCache: [String: Data] = [:]       // text+voice hash → WAV data (persists in memory)

    // MARK: - Init

    init() {
        let loadedConfig = ConfigStore.shared.load()
        let client = Self.makeLLMClient(config: loadedConfig)
        self.config = loadedConfig
        self.dialogueGenerator = DialogueGenerator(client: client)
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
                    error = "Groq API not reachable. Check your API key."
                case .ollama:
                    error = "Ollama not reachable at \(config.ollamaURL). Is it running?"
                }
                debugLog("[Theater] ERROR: \(error!)")
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
        watchTask?.cancel()
        watchTask = nil
        bufferTask?.cancel()
        bufferTask = nil
        coldOpenTask?.cancel()
        coldOpenTask = nil
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

    func skipCurrentLine() {
        audioPlayer.stopAll()
    }

    func clearHistory() {
        dialogueHistory.removeAll()
        eventLog.removeAll()
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

    // MARK: - Event Handling

    private func handleEvent(_ event: SessionEvent) {
        eventLog.append(event)
        if eventLog.count > 200 { eventLog.removeFirst() }

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
            self.triggerGeneration()
        }
    }

    private func triggerGeneration() {
        guard !isGenerating else { return }
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

            // Check for technical terms in the events — play contextual explainer filler
            let allTerms = eventsForTermDetect.map { $0.detail }
            if let explainer = FillerLibrary.termTriggeredFiller(forTerms: allTerms) {
                let lines = explainer.enumerated().map { i, text in
                    DialogueLine(characterIndex: i % 2, text: text)
                }
                debugLog("[Theater] Playing term-triggered explainer filler...")
                await self.playLines(lines)
            }

            if !self.eventBuffer.isEmpty {
                self.bufferStartTime = Date()
                self.phase = .buffering
                debugLog("[Theater] New events arrived during generation, rebuffering...")
                self.startBufferTimer()
            } else {
                self.startFillerGeneration()
            }
        }
    }

    /// Load pre-written filler banter and pre-synthesize voice for instant playback. No LLM needed.
    private func startFillerGeneration() {
        guard fillerQueue.isEmpty else { return }
        fillerTask?.cancel()
        fillerTask = Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }

            let fillers = FillerLibrary.randomSet(
                themeId: self.config.activeThemeId,
                characters: self.config.characters
            )
            guard !fillers.isEmpty else { return }

            debugLog("[Theater] Pre-synthesizing \(fillers.count) filler lines...")
            let cfg = self.config
            for line in fillers {
                guard !Task.isCancelled else { break }
                let charIdx = min(line.characterIndex, cfg.characters.count - 1)
                let voiceID = cfg.characters[charIdx].voiceID
                let _ = await self.synthesizeCached(text: line.text, voiceID: voiceID, speed: cfg.ttsSpeed)
            }

            self.fillerQueue = fillers
            debugLog("[Theater] \(fillers.count) fillers voice-cached and ready")
        }
    }

    /// Play fillers from the pre-cached queue. Returns true if fillers were played.
    private func playFillers() async -> Bool {
        guard !fillerQueue.isEmpty else { return false }
        let lines = fillerQueue
        fillerQueue.removeAll()

        debugLog("[Theater] Playing \(lines.count) cached fillers...")
        for line in lines {
            guard isRunning, !isGenerating else { break }

            phase = .playing
            currentLine = line
            currentSpeaker = line.characterIndex
            dialogueHistory.append(line)

            let charIdx = min(line.characterIndex, config.characters.count - 1)
            let voiceID = config.characters[charIdx].voiceID
            let cacheKey = "\(voiceID):\(line.text)"

            if let cached = voiceCache[cacheKey] {
                // Instant playback from cache!
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    audioPlayer.playOnce(data: cached) { cont.resume() }
                }
            } else {
                // Synthesize on the fly (shouldn't happen if pre-cached worked)
                let audio = await synthesizeCached(text: line.text, voiceID: voiceID, speed: config.ttsSpeed)
                if let audio {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        audioPlayer.playOnce(data: audio) { cont.resume() }
                    }
                } else {
                    try? await Task.sleep(for: .seconds(2.0))
                }
            }
        }

        currentLine = nil
        currentSpeaker = nil
        phase = isRunning ? .watching : .idle
        return true
    }

    /// Synthesize with voice cache — checks disk cache, then memory, then synthesizes.
    /// Persists to disk so fillers survive app restarts.
    private func synthesizeCached(text: String, voiceID: String, speed: Float) async -> Data? {
        let cacheKey = "\(voiceID):\(text)"
        let diskKey = cacheKey.data(using: .utf8)!.base64EncodedString()
            .prefix(40).replacingOccurrences(of: "/", with: "_")
        let diskPath = NSHomeDirectory() + "/.siliconvalley/voice_cache/\(diskKey).wav"

        // Check memory cache first
        if let cached = voiceCache[cacheKey] { return cached }

        // Check disk cache
        if let diskData = try? Data(contentsOf: URL(fileURLWithPath: diskPath)) {
            voiceCache[cacheKey] = diskData
            debugLog("[VoiceCache] Disk hit: \(text.prefix(30))...")
            return diskData
        }

        // Synthesize fresh
        let audio: Data?
        switch config.ttsProvider {
        case .sidecar, .kokoroSidecar:
            audio = await sidecarTTSManager.synthesize(text: text, voiceID: voiceID, speed: speed)
        case .fishAudio:
            audio = await fishTTSManager.synthesize(text: text, voiceID: voiceID, speed: speed)
        case .cartesia:
            audio = await cloudTTSManager.synthesize(text: text, voiceID: voiceID, speed: speed)
        case .disabled:
            audio = nil
        }

        if let audio {
            voiceCache[cacheKey] = audio
            // Persist to disk
            try? audio.write(to: URL(fileURLWithPath: diskPath))
            debugLog("[VoiceCache] Cached to disk: \(text.prefix(30))...")

            // Keep memory cache bounded
            if voiceCache.count > 80 {
                let oldest = voiceCache.keys.first!
                voiceCache.removeValue(forKey: oldest)
            }
        }
        return audio
    }

    // MARK: - Cold Open

    /// Play pre-baked intro banter while waiting for real events.
    private func playColdOpen() async {
        guard isRunning, !isGenerating else { return }

        let char0 = config.characters[0]
        let char1 = config.characters.count > 1 ? config.characters[1] : config.characters[0]

        // Detect project name from session file
        let projectHint: String
        if let path = watcher.currentSessionFile {
            let raw = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            projectHint = raw
                .replacingOccurrences(of: "-Users-sameeprehlan-", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "Documents ", with: "")
                .replacingOccurrences(of: "Claude Code ", with: "")
                .trimmingCharacters(in: .whitespaces)
        } else {
            projectHint = "some project"
        }

        // === PHASE 1: "Joining the call" intro (pre-written, will be voice-cached) ===
        let joiners: [[(Int, String)]] = [
            [
                (0, "Richard's calling. He probably broke something again."),
                (1, "It's about that \(projectHint) thing he's been working on."),
                (0, "Let me guess. He wants us to fix it while he takes credit."),
                (1, "That's literally every standup. But sure, let's join."),
                (0, "Alright. I'm in. What's he saying?"),
                (1, "Hold on, let me pull it up. Okay I can see the session."),
            ],
            [
                (1, "Oh great, Richard's on the line. This should be fun."),
                (0, "He's working on \(projectHint). Wants our help apparently."),
                (1, "Our help. Meaning he wants ME to do the work and YOU to judge it."),
                (0, "That's a fair description of our dynamic, yes."),
                (1, "Fine. Let's see what he's gotten himself into this time."),
                (0, "Connecting now. Try to look like you care."),
            ],
            [
                (0, "Incoming call from Richard. \(projectHint) related."),
                (1, "Didn't he say he could handle this one on his own?"),
                (0, "He says that every time. And every time, here we are."),
                (1, "True. Remember the last time he went solo? Three day outage."),
                (0, "That's exactly why we're joining. Let's go."),
                (1, "Alright, I'm here. What's happening on his end?"),
            ],
        ]

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
            let c0Name = char0.name
            let c1Name = char1.name
            let proj = projectHint

            contextGenTask = Task.detached {
                let prompt = """
                Write 6 lines. \(c0Name) and \(c1Name) discuss what Richard (their boss) just asked them to work on. Explain what it means simply. Stay in character. Under 25 words each.

                Richard wants help with \(proj). He said: "\(String(msg.prefix(200)))"

                \(theme?.fewShotExample ?? "")

                \(c0Name):
                \(c1Name):
                \(c0Name):
                \(c1Name):
                \(c0Name):
                \(c1Name):
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

        // Pool of cold open variations — combining joiners with filler banter
        let openers = joiners

        // Pick a different opener each time (avoid repeats)
        var pick = Int.random(in: 0..<openers.count)
        if pick == lastColdOpenIndex && openers.count > 1 {
            pick = (pick + 1) % openers.count
        }
        lastColdOpenIndex = pick
        let chosen = openers[pick]
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
                // Play a random filler set instead
                let fillers = FillerLibrary.randomSet(themeId: config.activeThemeId, characters: config.characters)
                if !fillers.isEmpty {
                    await playLines(fillers)
                }
            }
        } else {
            // No user message yet — play fillers while waiting
            let fillers = FillerLibrary.randomSet(themeId: config.activeThemeId, characters: config.characters)
            if !fillers.isEmpty {
                debugLog("[Theater] No user message yet — playing filler banter...")
                await playLines(fillers)
            }
        }

        // Start pre-caching more fillers for future gaps
        startFillerGeneration()

        currentLine = nil
        currentSpeaker = nil
        phase = isRunning ? .watching : .idle
        debugLog("[Theater] Intro sequence done")
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
            lines = try await Task.detached {
                try await generator.generate(events: events, config: cfg, activeTheme: activeTheme)
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
