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

    // Audio
    var masterVolume: Float

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
        masterVolume: Float = 0.8,
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
        self.masterVolume = masterVolume
        self.sessionThemeMap = sessionThemeMap
    }

    // Backward-compatible decoding: sessionThemeMap may not exist in old configs
    enum CodingKeys: String, CodingKey {
        case activeThemeId, characters, systemPrompt
        case llmProvider, groqApiKey, groqModel, ollamaModel, ollamaURL
        case ttsProvider, cartesiaApiKey, fishAudioApiKey, ttsEnabled, ttsSpeed, bufferDuration
        case masterVolume, sessionThemeMap
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
        masterVolume = (try? c.decode(Float.self, forKey: .masterVolume)) ?? 0.8
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
    /// Auto-resolves avatar images from Resources/Avatars/{characterId}.png if present.
    mutating func applyTheme(_ theme: CharacterTheme) {
        activeThemeId = theme.id
        characters = theme.characters.map { char in
            var c = char
            if c.avatarPath == nil {
                c.avatarPath = Self.resolveAvatar(for: char.id)
            }
            return c
        }
        systemPrompt = theme.systemPrompt
    }

    /// Resolve avatar path for a character ID from Resources/Avatars/.
    static func resolveAvatar(for characterId: String) -> String? {
        let bundlePath = Bundle.main.bundlePath
        let basePath: String
        if bundlePath.contains("/build/") {
            basePath = bundlePath.components(separatedBy: "/build/").first ?? bundlePath
        } else {
            basePath = (bundlePath as NSString).deletingLastPathComponent
        }
        let avatarDir = basePath + "/Resources/Avatars"
        for ext in ["png", "jpg", "jpeg", "webp"] {
            let path = "\(avatarDir)/\(characterId).\(ext)"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Resolve the user's avatar based on the active theme's user character.
    static func userAvatarPath(for theme: CharacterTheme?) -> String? {
        let name = theme?.userCharacterName ?? "Richard"
        return resolveAvatar(for: name.lowercased())
    }

    /// Fallback for backward compatibility.
    static var userAvatarPath: String? {
        resolveAvatar(for: "richard")
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
            ttsProvider: .disabled,
            cartesiaApiKey: "",
            fishAudioApiKey: "",
            ttsEnabled: true,
            ttsSpeed: 1.0,
            bufferDuration: 60,
            masterVolume: 0.8,
            sessionThemeMap: [:]
        )
    }()
}

// MARK: - Config Storage

final class ConfigStore {
    static let shared = ConfigStore()

    private let queue = DispatchQueue(label: "com.siliconvalley.configstore")
    private var saveWorkItem: DispatchWorkItem?

    private let configURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".siliconvalley")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    func load() -> TheaterConfig {
        queue.sync {
            guard FileManager.default.fileExists(atPath: configURL.path),
                  let data = try? Data(contentsOf: configURL),
                  let config = try? JSONDecoder().decode(TheaterConfig.self, from: data)
            else {
                return .default
            }
            return config
        }
    }

    /// Debounced save — coalesces rapid writes (e.g. volume slider) into max 1 per 0.5s.
    func save(_ config: TheaterConfig) {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [configURL] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(config) else { return }
            try? data.write(to: configURL, options: .atomic)
        }
        saveWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
