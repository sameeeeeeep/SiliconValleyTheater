import Foundation

// MARK: - CloudTTSManager

/// Cloud TTS with voice cloning via Cartesia's Sonic API.
/// Clones voices from reference WAV files on first use, caches embeddings locally.
@Observable
final class CloudTTSManager {

    private(set) var isReady = false
    private(set) var isStarting = false

    private var apiKey: String = ""
    private var voiceEmbeddings: [String: [Double]] = [:] // voiceID → embedding

    // Map character voice IDs → Cartesia built-in voice IDs (free tier)
    static let builtinVoiceMap: [String: String] = [
        "gilfoyle": "a0e99841-438c-4a64-b679-ae501e7d6091",  // Barbershop Man (deep, dry)
        "dinesh":   "79a125e8-cd45-4c13-8a67-188112f4dd22",  // British Lady
        "rick":     "fb26447f-308b-471e-8b00-f1e1cb7953a8",  // Wizened Man
        "morty":    "d46abd1d-2571-4050-a8c3-c75a3ad5e8e1",  // Young Narrator
        "sherlock": "2ee87190-8f84-4925-97da-e52547f9462c",  // Classy British Man
        "watson":   "79a125e8-cd45-4c13-8a67-188112f4dd22",  // British Lady
        "chandler": "d46abd1d-2571-4050-a8c3-c75a3ad5e8e1",  // Young Narrator
        "joey":     "a0e99841-438c-4a64-b679-ae501e7d6091",  // Barbershop Man
        "dwight":   "fb26447f-308b-471e-8b00-f1e1cb7953a8",  // Wizened Man
        "jim":      "d46abd1d-2571-4050-a8c3-c75a3ad5e8e1",  // Young Narrator
        "jesse":    "d46abd1d-2571-4050-a8c3-c75a3ad5e8e1",  // Young Narrator
        "walter":   "fb26447f-308b-471e-8b00-f1e1cb7953a8",  // Wizened Man
        "tony":     "a0e99841-438c-4a64-b679-ae501e7d6091",  // Barbershop Man
        "jarvis":   "2ee87190-8f84-4925-97da-e52547f9462c",  // Classy British Man
    ]
    private let cacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".siliconvalley")
            .appendingPathComponent("voice_cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Setup

    func configure(apiKey: String) {
        self.apiKey = apiKey
        self.isReady = !apiKey.isEmpty
    }

    /// Try to clone voices from reference WAV files. Falls back to built-in voices if cloning unavailable.
    func warmUpVoices(voiceIDs: [String]) async {
        guard !apiKey.isEmpty else { return }
        isStarting = true

        for voiceID in voiceIDs {
            // Check disk cache first
            if let cached = loadCachedEmbedding(voiceID: voiceID) {
                voiceEmbeddings[voiceID] = cached
                debugLog("[CloudTTS] Loaded cached embedding for '\(voiceID)'")
                continue
            }

            // Find reference WAV
            guard let wavPath = findReferenceWAV(voiceID: voiceID) else {
                debugLog("[CloudTTS] No reference WAV for '\(voiceID)', will use built-in voice")
                continue
            }

            // Try cloning via Cartesia API (may fail on free tier)
            debugLog("[CloudTTS] Cloning voice '\(voiceID)' from \(wavPath)...")
            if let embedding = await cloneVoice(wavPath: wavPath) {
                voiceEmbeddings[voiceID] = embedding
                saveCachedEmbedding(voiceID: voiceID, embedding: embedding)
                debugLog("[CloudTTS] Voice '\(voiceID)' cloned successfully")
            } else {
                let hasBuiltin = Self.builtinVoiceMap[voiceID.lowercased()] != nil
                debugLog("[CloudTTS] Clone unavailable for '\(voiceID)', using built-in voice: \(hasBuiltin)")
            }
        }

        isStarting = false
        isReady = !apiKey.isEmpty
        let cloned = voiceEmbeddings.count
        let builtin = voiceIDs.filter { Self.builtinVoiceMap[$0.lowercased()] != nil }.count
        debugLog("[CloudTTS] Ready — \(cloned) cloned, \(builtin) built-in voices available")
    }

    // MARK: - Synthesis

    func synthesize(text: String, voiceID: String, speed: Float = 1.0) async -> Data? {
        guard !apiKey.isEmpty else { return nil }

        guard let url = URL(string: "https://api.cartesia.ai/tts/bytes") else { return nil }

        // Build voice config — use cloned embedding if available, otherwise built-in voice
        let voiceConfig: [String: Any]
        if let embedding = voiceEmbeddings[voiceID.lowercased()] ?? voiceEmbeddings[voiceID] {
            voiceConfig = [
                "mode": "embedding",
                "embedding": embedding
            ]
        } else if let builtinID = Self.builtinVoiceMap[voiceID.lowercased()] {
            voiceConfig = [
                "mode": "id",
                "id": builtinID
            ]
        } else {
            // Alternate between two default voices based on stable character index
            // (hashValue is non-deterministic across launches, so use character count instead)
            let stableIndex = voiceID.utf8.reduce(0) { $0 &+ Int($1) }
            let fallbackID = stableIndex % 2 == 0
                ? "a0e99841-438c-4a64-b679-ae501e7d6091"  // Barbershop Man
                : "79a125e8-cd45-4c13-8a67-188112f4dd22"  // British Lady
            voiceConfig = [
                "mode": "id",
                "id": fallbackID
            ]
            debugLog("[CloudTTS] No embedding for '\(voiceID)', using built-in voice")
        }

        let payload: [String: Any] = [
            "model_id": "sonic-2",
            "transcript": text,
            "voice": voiceConfig,
            "output_format": [
                "container": "wav",
                "sample_rate": 44100,
                "encoding": "pcm_s16le"
            ],
            "language": "en"
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("2024-06-10", forHTTPHeaderField: "Cartesia-Version")
        request.timeoutInterval = 15

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse else { return nil }
            if http.statusCode == 200 {
                debugLog("[CloudTTS] Synthesized '\(text.prefix(40))...' → \(data.count) bytes")
                return data
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                debugLog("[CloudTTS] Synthesis failed HTTP \(http.statusCode): \(body.prefix(200))")
                return nil
            }
        } catch {
            debugLog("[CloudTTS] Synthesis error: \(error)")
            return nil
        }
    }

    // MARK: - Voice Cloning

    private func cloneVoice(wavPath: String) async -> [Double]? {
        guard let url = URL(string: "https://api.cartesia.ai/voices/clone/clip") else { return nil }

        let wavData: Data
        do {
            wavData = try Data(contentsOf: URL(fileURLWithPath: wavPath))
        } catch {
            debugLog("[CloudTTS] Could not read WAV: \(error)")
            return nil
        }

        // Build multipart form data
        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"clip\"; filename=\"reference.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("2024-06-10", forHTTPHeaderField: "Cartesia-Version")
        request.timeoutInterval = 30
        request.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                debugLog("[CloudTTS] Clone failed: \(body.prefix(200))")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let embedding = json["embedding"] as? [Double]
            else {
                debugLog("[CloudTTS] Could not parse clone response")
                return nil
            }

            return embedding
        } catch {
            debugLog("[CloudTTS] Clone error: \(error)")
            return nil
        }
    }

    // MARK: - Reference WAV Lookup

    private func findReferenceWAV(voiceID: String) -> String? {
        let aliases: [String: String] = [
            "gilfoyle": "David",
            "dinesh": "Moira",
            "david-rose": "David",
            "moira-rose": "Moira",
        ]

        let resolved = aliases[voiceID.lowercased()] ?? voiceID
        let bundlePath = Bundle.main.bundlePath

        let projectRoot: String
        if bundlePath.contains("/build/") {
            projectRoot = bundlePath.components(separatedBy: "/build/").first ?? bundlePath
        } else {
            projectRoot = (bundlePath as NSString).deletingLastPathComponent
        }

        let voicesDir = "\(projectRoot)/Resources/Voices"
        var searchPaths = [
            "\(voicesDir)/\(resolved).wav",
            "\(voicesDir)/\(voiceID).wav",
            "\(projectRoot)/TTSSidecar/voices/\(resolved).wav",
            "\(projectRoot)/TTSSidecar/voices/\(voiceID).wav",
        ]
        // Search theme subdirectories
        if let subdirs = try? FileManager.default.contentsOfDirectory(atPath: voicesDir) {
            for subdir in subdirs {
                let subPath = "\(voicesDir)/\(subdir)"
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue {
                    searchPaths.append("\(subPath)/\(resolved).wav")
                    searchPaths.append("\(subPath)/\(voiceID).wav")
                    searchPaths.append("\(subPath)/\(resolved.lowercased()).wav")
                }
            }
        }

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Embedding Cache

    private func loadCachedEmbedding(voiceID: String) -> [Double]? {
        let file = cacheDir.appendingPathComponent("\(voiceID).json")
        guard let data = try? Data(contentsOf: file),
              let embedding = try? JSONDecoder().decode([Double].self, from: data)
        else { return nil }
        return embedding
    }

    private func saveCachedEmbedding(voiceID: String, embedding: [Double]) {
        let file = cacheDir.appendingPathComponent("\(voiceID).json")
        if let data = try? JSONEncoder().encode(embedding) {
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: - Health

    func checkHealth() async -> Bool {
        guard !apiKey.isEmpty else { return false }
        guard let url = URL(string: "https://api.cartesia.ai/voices") else { return false }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("2024-06-10", forHTTPHeaderField: "Cartesia-Version")
        request.timeoutInterval = 10

        do {
            let (_, resp) = try await URLSession.shared.data(for: request)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
