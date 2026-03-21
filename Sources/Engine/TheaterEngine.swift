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
        generateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateAndPlay(events: events)
            self.isGenerating = false

            guard self.isRunning else {
                self.phase = .idle
                return
            }

            if !self.eventBuffer.isEmpty {
                self.bufferStartTime = Date()
                self.phase = .buffering
                debugLog("[Theater] New events arrived during generation, rebuffering...")
                self.startBufferTimer()
            }
        }
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

        // Pool of cold open variations — pick one at random
        let openers: [[(Int, String)]] = [
            [
                (0, "Alright, looks like we're working on \(projectHint) today."),
                (1, "Wait, are we actually doing this? I thought this was optional."),
                (0, "Nothing is optional when the codebase looks like this."),
                (1, "Okay fine. Let me see what we're dealing with here."),
            ],
            [
                (1, "So what's on the agenda? Please tell me it's not another refactor."),
                (0, "We're on \(projectHint). And yes, it's probably a refactor."),
                (1, "Every time. Every single time."),
                (0, "Stop complaining and open the file."),
            ],
            [
                (0, "I see we've been assigned to \(projectHint). Interesting."),
                (1, "You say interesting like someone just handed you a crime scene."),
                (0, "Have you seen this codebase? It basically is one."),
                (1, "Okay dramatic. Let's just get started."),
            ],
            [
                (1, "Morning. What fresh disaster are we walking into today?"),
                (0, "\(projectHint). Could be worse."),
                (1, "Could be worse? That's the most optimistic thing you've ever said."),
                (0, "Don't get used to it. I haven't read the code yet."),
            ],
            [
                (0, "Pull up \(projectHint). We've got work to do."),
                (1, "Already? I haven't even finished my coffee."),
                (0, "Your coffee is not a dependency. The build is."),
                (1, "Technically my productivity depends on caffeine, so yes it is."),
            ],
            [
                (1, "Okay I'm looking at \(projectHint) and I have questions."),
                (0, "You always have questions. That's not new."),
                (1, "My questions are valid! Last time I asked one, we found a memory leak."),
                (0, "That was an accident. But fine. Ask away."),
            ],
        ]

        // Pick a different opener each time (avoid repeats)
        var pick = Int.random(in: 0..<openers.count)
        if pick == lastColdOpenIndex && openers.count > 1 {
            pick = (pick + 1) % openers.count
        }
        lastColdOpenIndex = pick
        let chosen = openers[pick]
        let coldLines = chosen.map { DialogueLine(characterIndex: $0.0, text: $0.1) }

        debugLog("[Theater] Playing cold open (\(coldLines.count) lines)...")

        // Synthesize and play
        let useTTS = config.ttsEnabled && ttsReady && config.ttsProvider != .disabled
        for line in coldLines {
            guard isRunning, !isGenerating else {
                debugLog("[Theater] Cold open interrupted by real generation")
                break
            }

            phase = .playing
            currentLine = line
            currentSpeaker = line.characterIndex
            dialogueHistory.append(line)

            if useTTS {
                let charIdx = min(line.characterIndex, config.characters.count - 1)
                let voiceID = config.characters[charIdx].voiceID
                let speed = config.ttsSpeed

                let audio: Data?
                switch config.ttsProvider {
                case .sidecar, .kokoroSidecar:
                    audio = await sidecarTTSManager.synthesize(text: line.text, voiceID: voiceID, speed: speed)
                case .fishAudio:
                    audio = await fishTTSManager.synthesize(text: line.text, voiceID: voiceID, speed: speed)
                case .cartesia:
                    audio = await cloudTTSManager.synthesize(text: line.text, voiceID: voiceID, speed: speed)
                case .disabled:
                    audio = nil
                }

                if let audio = audio {
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

        currentLine = nil
        currentSpeaker = nil
        phase = isRunning ? .watching : .idle
        debugLog("[Theater] Cold open done")
    }

    /// Send events to LLM for dialogue generation, then play with pipelined TTS.
    private func generateAndPlay(events: [SessionEvent]) async {
        phase = .generating
        debugLog("[Theater] Flushing \(events.count) events to \(config.llmProvider.rawValue)...")

        let generator = dialogueGenerator
        let cfg = config
        let lines: [DialogueLine]
        do {
            lines = try await Task.detached {
                try await generator.generate(events: events, config: cfg)
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
