import Foundation

// MARK: - TTSManager

/// Manages the Qwen3-TTS Python sidecar server and provides TTS synthesis.
@Observable
final class TTSManager {

    private(set) var isRunning = false
    private(set) var isReady = false

    static let port = 7893
    static let baseURL = "http://127.0.0.1:\(port)"

    private var sidecarProcess: Process?

    // MARK: - Health Check

    func checkHealth() async -> Bool {
        guard let url = URL(string: "\(Self.baseURL)/health") else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            await MainActor.run { self.isReady = ok }
            return ok
        } catch {
            await MainActor.run { self.isReady = false }
            return false
        }
    }

    // MARK: - Start/Stop Sidecar

    /// Start the TTS sidecar server with the specified engine.
    func startSidecar(engine: String = "pocket") async {
        // Check if already running externally
        if await checkHealth() {
            debugLog("[TTS] Sidecar already running")
            return
        }

        // Find server.py + venv relative to the app bundle
        let bundlePath = Bundle.main.bundlePath
        let sidecarDir: String
        if bundlePath.contains("/build/") {
            sidecarDir = bundlePath.components(separatedBy: "/build/").first! + "/TTSSidecar"
        } else {
            sidecarDir = (bundlePath as NSString).deletingLastPathComponent + "/TTSSidecar"
        }

        let serverScript = sidecarDir + "/server.py"
        guard FileManager.default.fileExists(atPath: serverScript) else {
            debugLog("[TTS] server.py not found at \(serverScript)")
            return
        }

        // Use venv Python if available, otherwise system python3
        let venvPython = sidecarDir + "/.venv/bin/python3"
        let pythonPath = FileManager.default.fileExists(atPath: venvPython) ? venvPython : "/usr/bin/env"
        let args: [String]
        if pythonPath == venvPython {
            args = [serverScript, "--port", "\(Self.port)", "--engine", engine]
        } else {
            args = ["python3", serverScript, "--port", "\(Self.port)", "--engine", engine]
        }

        debugLog("[TTS] Starting \(engine) sidecar (python: \(pythonPath))...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: sidecarDir)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                for line in text.split(separator: "\n") {
                    debugLog("[TTS-py] \(line)")
                }
            }
        }

        do {
            try process.run()
            sidecarProcess = process
            await MainActor.run { self.isRunning = true }

            // Poll for readiness (model loading can take a while on first run)
            for attempt in 1...90 {
                try? await Task.sleep(for: .seconds(2))
                if !process.isRunning {
                    debugLog("[TTS] Sidecar process exited (code \(process.terminationStatus))")
                    await MainActor.run { self.isRunning = false }
                    break
                }
                if await checkHealth() {
                    debugLog("[TTS] Sidecar ready after \(attempt * 2)s (\(engine))")
                    return
                }
            }
            debugLog("[TTS] Sidecar did not become ready")
        } catch {
            debugLog("[TTS] Failed to start sidecar: \(error)")
        }
    }

    func stopSidecar() {
        sidecarProcess?.terminate()
        sidecarProcess = nil
        isRunning = false
        isReady = false
    }

    // MARK: - Synthesize Single Line

    func synthesize(text: String, voiceID: String, speed: Float = 1.0) async -> Data? {
        guard isReady else { return nil }
        guard let url = URL(string: "\(Self.baseURL)/synthesize") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let payload: [String: Any] = ["text": text, "voice_id": voiceID, "speed": speed]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Synthesize Dialogue Batch

    func synthesizeDialogue(turns: [(text: String, voiceID: String)], speed: Float = 1.0) async -> [Data?] {
        guard isReady else { return Array(repeating: nil, count: turns.count) }
        guard let url = URL(string: "\(Self.baseURL)/synthesize_dialogue") else {
            return Array(repeating: nil, count: turns.count)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Double(turns.count) * 60

        let turnsPayload = turns.map { ["text": $0.text, "voice_id": $0.voiceID] }
        let payload: [String: Any] = ["turns": turnsPayload, "speed": speed]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audioList = json["audio"] as? [String?]
            else {
                return Array(repeating: nil, count: turns.count)
            }
            return audioList.map { $0.flatMap { Data(base64Encoded: $0) } }
        } catch {
            return Array(repeating: nil, count: turns.count)
        }
    }
}
