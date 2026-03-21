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
            ollamaModel: "llama3.2",
            ollamaURL: "http://localhost:11434",
            ttsProvider: .sidecar,
            cartesiaApiKey: "",
            fishAudioApiKey: "",
            ttsEnabled: true,
            ttsSpeed: 1.0,
            bufferDuration: 15
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
