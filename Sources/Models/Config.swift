import Foundation

// MARK: - Provider Enums

enum LLMProvider: String, Codable, CaseIterable {
    case groq = "Groq"
    case ollama = "Ollama"
}

enum TTSProvider: String, Codable, CaseIterable {
    case sidecar = "Pocket TTS (Local)"
    case kokoroSidecar = "Kokoro (Local, Fast)"
    case fishAudio = "Fish Audio"
    case cartesia = "Cartesia (Cloud)"
    case disabled = "Disabled"
}

// MARK: - CharacterConfig

struct CharacterConfig: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var personality: String
    var speechStyle: String
    var catchphrases: [String]
    var avatarPath: String?
    var voiceID: String
    var role: CharacterRole

    enum CharacterRole: String, Codable, Hashable {
        case explainer
        case questioner
    }
}

// MARK: - TheaterConfig

struct TheaterConfig: Codable {
    var activeThemeId: String
    var characters: [CharacterConfig]
    var systemPrompt: String

    // LLM settings
    var llmProvider: LLMProvider
    var groqApiKey: String
    var groqModel: String
    var ollamaModel: String
    var ollamaURL: String

    // TTS settings
    var ttsProvider: TTSProvider
    var cartesiaApiKey: String
    var fishAudioApiKey: String
    var ttsEnabled: Bool
    var ttsSpeed: Float
    var bufferDuration: TimeInterval

    // Multi-room: maps session path -> theme ID
    var sessionThemeMap: [String: String]

    // Explicit memberwise init (needed because custom init(from:) suppresses the auto one)
    init(
        activeThemeId: String,
        characters: [CharacterConfig],
        systemPrompt: String,
        llmProvider: LLMProvider,
        groqApiKey: String,
        groqModel: String,
        ollamaModel: String,
        ollamaURL: String,
        ttsProvider: TTSProvider,
        cartesiaApiKey: String,
        fishAudioApiKey: String,
        ttsEnabled: Bool,
        ttsSpeed: Float,
        bufferDuration: TimeInterval,
        sessionThemeMap: [String: String] = [:]
    ) {
        self.activeThemeId = activeThemeId
        self.characters = characters
        self.systemPrompt = systemPrompt
        self.llmProvider = llmProvider
        self.groqApiKey = groqApiKey
        self.groqModel = groqModel
        self.ollamaModel = ollamaModel
        self.ollamaURL = ollamaURL
        self.ttsProvider = ttsProvider
        self.cartesiaApiKey = cartesiaApiKey
        self.fishAudioApiKey = fishAudioApiKey
        self.ttsEnabled = ttsEnabled
        self.ttsSpeed = ttsSpeed
        self.bufferDuration = bufferDuration
        self.sessionThemeMap = sessionThemeMap
    }

    // Backward-compatible decoding: sessionThemeMap may not exist in old configs
    enum CodingKeys: String, CodingKey {
        case activeThemeId, characters, systemPrompt
        case llmProvider, groqApiKey, groqModel, ollamaModel, ollamaURL
        case ttsProvider, cartesiaApiKey, fishAudioApiKey, ttsEnabled, ttsSpeed, bufferDuration
        case sessionThemeMap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeThemeId = try c.decode(String.self, forKey: .activeThemeId)
        characters = try c.decode([CharacterConfig].self, forKey: .characters)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        llmProvider = try c.decode(LLMProvider.self, forKey: .llmProvider)
        groqApiKey = try c.decode(String.self, forKey: .groqApiKey)
        groqModel = try c.decode(String.self, forKey: .groqModel)
        ollamaModel = try c.decode(String.self, forKey: .ollamaModel)
        ollamaURL = try c.decode(String.self, forKey: .ollamaURL)
        ttsProvider = try c.decode(TTSProvider.self, forKey: .ttsProvider)
        cartesiaApiKey = try c.decode(String.self, forKey: .cartesiaApiKey)
        fishAudioApiKey = try c.decode(String.self, forKey: .fishAudioApiKey)
        ttsEnabled = try c.decode(Bool.self, forKey: .ttsEnabled)
        ttsSpeed = try c.decode(Float.self, forKey: .ttsSpeed)
        bufferDuration = try c.decode(TimeInterval.self, forKey: .bufferDuration)
        sessionThemeMap = (try? c.decode([String: String].self, forKey: .sessionThemeMap)) ?? [:]
    }

    /// Get the theme assigned to a session, falling back to the global active theme.
    func themeId(forSession sessionPath: String) -> String {
        sessionThemeMap[sessionPath] ?? activeThemeId
    }

    /// Assign a theme to a specific session.
    mutating func setTheme(_ themeId: String, forSession sessionPath: String) {
        sessionThemeMap[sessionPath] = themeId
    }

    /// Apply a theme's characters and system prompt.
    mutating func applyTheme(_ theme: CharacterTheme) {
        activeThemeId = theme.id
        characters = theme.characters
        systemPrompt = theme.systemPrompt
    }

    static let `default`: TheaterConfig = {
        let theme = BuiltInThemes.gilfoyleAndDinesh
        return TheaterConfig(
            activeThemeId: theme.id,
            characters: theme.characters,
            systemPrompt: theme.systemPrompt,
            llmProvider: .groq,
            groqApiKey: "",
            groqModel: "llama-3.3-70b-versatile",
            ollamaModel: "qwen2.5:3b",
            ollamaURL: "http://localhost:11434",
            ttsProvider: .sidecar,
            cartesiaApiKey: "",
            fishAudioApiKey: "",
            ttsEnabled: true,
            ttsSpeed: 1.0,
            bufferDuration: 60,
            sessionThemeMap: [:]
        )
    }()
}

// MARK: - Config Storage

final class ConfigStore {
    static let shared = ConfigStore()

    private let configURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".siliconvalley")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    func load() -> TheaterConfig {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(TheaterConfig.self, from: data)
        else {
            return .default
        }
        return config
    }

    func save(_ config: TheaterConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }
}
