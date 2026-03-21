import Foundation

// MARK: - FishAudioTTSManager

/// Cloud TTS with voice cloning via Fish Audio.
/// On warmup: creates a voice model from reference WAV (once), caches the model ID.
/// On synthesis: sends only text + cached model ID — fast, no audio upload.
/// Pricing: ~$15/million chars, pay-as-you-go.
@Observable
final class FishAudioTTSManager {

    private(set) var isReady = false
    private(set) var isStarting = false

    private var apiKey: String = ""
    /// voiceID → Fish Audio model UUID (persisted to disk)
    private var modelIDs: [String: String] = [:]

    private let cacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".siliconvalley")
            .appendingPathComponent("fish_cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Setup

    func configure(apiKey: String) {
        self.apiKey = apiKey
        self.isReady = !apiKey.isEmpty
    }

    /// Create Fish Audio voice models from reference WAVs (one-time per voice).
    /// Cached model IDs are reused on subsequent launches — no re-upload.
    func warmUpVoices(voiceIDs: [String]) async {
        guard !apiKey.isEmpty else { return }
        isStarting = true

        for voiceID in voiceIDs {
            let key = voiceID.lowercased()

            // 1. Check disk cache
            if let cached = loadCachedModelID(voiceID: key) {
                modelIDs[key] = cached
                debugLog("[FishTTS] Cached model for '\(voiceID)': \(cached.prefix(12))...")
                continue
            }

            // 2. Find reference WAV
            guard let wavPath = findReferenceWAV(voiceID: voiceID) else {
                debugLog("[FishTTS] No reference WAV for '\(voiceID)', will use default voice")
                continue
            }

            // 3. Upload WAV to create a persistent model
            debugLog("[FishTTS] Creating voice model for '\(voiceID)'...")
            if let modelID = await createVoiceModel(voiceID: voiceID, wavPath: wavPath) {
                modelIDs[key] = modelID
                saveCachedModelID(voiceID: key, modelID: modelID)
                debugLog("[FishTTS] Model created for '\(voiceID)': \(modelID.prefix(12))...")
            } else {
                debugLog("[FishTTS] Model creation failed for '\(voiceID)', will use default voice")
            }
        }

        isStarting = false
        isReady = !apiKey.isEmpty
        debugLog("[FishTTS] Ready — \(modelIDs.count) voice model(s)")
    }

    // MARK: - Synthesis (lightweight — just text + model ID)

    func synthesize(text: String, voiceID: String, speed: Float = 1.0) async -> Data? {
        guard !apiKey.isEmpty else { return nil }
        guard let url = URL(string: "https://api.fish.audio/v1/tts") else { return nil }

        var payload: [String: Any] = [
            "text": text,
            "format": "wav",
            "sample_rate": 44100,
            "latency": "balanced",
            "temperature": 0.7,
            "top_p": 0.8,
        ]

        if abs(speed - 1.0) > 0.05 {
            payload["prosody"] = ["speed": speed]
        }

        // Use cached model ID (lightweight reference, no audio sent)
        let key = voiceID.lowercased()
        if let modelID = modelIDs[key] {
            payload["reference_id"] = modelID
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("s1", forHTTPHeaderField: "model")
        request.timeoutInterval = 20

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse else { return nil }
            if http.statusCode == 200 {
                debugLog("[FishTTS] '\(text.prefix(30))...' → \(data.count / 1024)KB")
                return data
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                debugLog("[FishTTS] HTTP \(http.statusCode): \(body.prefix(200))")
                return nil
            }
        } catch {
            debugLog("[FishTTS] Error: \(error)")
            return nil
        }
    }

    // MARK: - Voice Model Creation (one-time upload)

    private func createVoiceModel(voiceID: String, wavPath: String) async -> String? {
        guard let url = URL(string: "https://api.fish.audio/model") else { return nil }

        let wavData: Data
        do {
            wavData = try Data(contentsOf: URL(fileURLWithPath: wavPath))
        } catch {
            debugLog("[FishTTS] Cannot read WAV: \(error)")
            return nil
        }

        // Multipart form: type, title, visibility, train_mode, voices (file)
        let boundary = "FishAudio-\(UUID().uuidString)"
        var body = Data()

        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        addField("type", "tts")
        addField("title", "SV-\(voiceID)")
        addField("visibility", "private")
        addField("train_mode", "fast")

        // Add WAV file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"voices\"; filename=\"\(voiceID).wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        request.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse else { return nil }

            if http.statusCode == 200 || http.statusCode == 201 {
                // Parse model ID from response
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let modelID = json["_id"] as? String ?? (json["id"] as? String) {
                    return modelID
                }
                debugLog("[FishTTS] Model created but no ID in response")
                return nil
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                debugLog("[FishTTS] Model creation HTTP \(http.statusCode): \(body.prefix(300))")
                return nil
            }
        } catch {
            debugLog("[FishTTS] Model creation error: \(error)")
            return nil
        }
    }

    // MARK: - Reference WAV Lookup

    private func findReferenceWAV(voiceID: String) -> String? {
        let aliases: [String: String] = [
            "gilfoyle": "David",
            "dinesh": "Moira",
        ]

        let resolved = aliases[voiceID.lowercased()] ?? voiceID
        let bundlePath = Bundle.main.bundlePath
        let projectRoot: String
        if bundlePath.contains("/build/") {
            projectRoot = bundlePath.components(separatedBy: "/build/").first!
        } else {
            projectRoot = (bundlePath as NSString).deletingLastPathComponent
        }

        for path in [
            "\(projectRoot)/Resources/Voices/\(resolved).wav",
            "\(projectRoot)/Resources/Voices/\(voiceID).wav",
            "\(projectRoot)/TTSSidecar/voices/\(resolved).wav",
            "\(projectRoot)/TTSSidecar/voices/\(voiceID).wav",
        ] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Cache

    private func loadCachedModelID(voiceID: String) -> String? {
        let file = cacheDir.appendingPathComponent("\(voiceID).txt")
        return try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveCachedModelID(voiceID: String, modelID: String) {
        let file = cacheDir.appendingPathComponent("\(voiceID).txt")
        try? modelID.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Health (lightweight — just check API key validity)

    func checkHealth() async -> Bool {
        guard !apiKey.isEmpty else { return false }
        // Use the model list endpoint — lightweight, no TTS burn
        guard let url = URL(string: "https://api.fish.audio/model?page_size=1&page_number=1") else { return false }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8

        do {
            let (_, resp) = try await URLSession.shared.data(for: request)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
