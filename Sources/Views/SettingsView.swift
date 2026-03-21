import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(TheaterEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var editingConfig: TheaterConfig = .default
    @State private var selectedTab = 0

    var body: some View {
        @Bindable var eng = engine

        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Themes").tag(0)
                Text("Characters").tag(1)
                Text("Connection").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            TabView(selection: $selectedTab) {
                themesTab.tag(0)
                charactersTab.tag(1)
                connectionTab.tag(2)
            }
            .tabViewStyle(.automatic)

            Divider()

            // Save / Cancel
            HStack {
                Button("Reset to Defaults") {
                    editingConfig = .default
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    engine.config = editingConfig
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 500)
        .onAppear { editingConfig = engine.config }
    }

    // MARK: - Themes Tab

    private var themesTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(ThemeStore.shared.allThemes()) { theme in
                    themeCard(theme)
                }
            }
            .padding()
        }
    }

    private func themeCard(_ theme: CharacterTheme) -> some View {
        let isActive = editingConfig.activeThemeId == theme.id

        return Button {
            editingConfig.applyTheme(theme)
        } label: {
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(String(theme.characters[0].name.prefix(1)))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.cyan)
                    Text(String(theme.characters.count > 1
                        ? String(theme.characters[1].name.prefix(1))
                        : "?"))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)
                }
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(theme.name)
                            .font(.body)
                            .fontWeight(.medium)
                        Text(theme.show)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Text(theme.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(10)
            .background(
                isActive ? Color.white.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isActive ? Color.green.opacity(0.4) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Characters Tab

    private var charactersTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(editingConfig.characters.indices, id: \.self) { i in
                    characterEditor(index: i)
                }
            }
            .padding()
        }
    }

    private func characterEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(index == 0 ? "Character 1 (Explainer)" : "Character 2 (Questioner)")
                .font(.headline)

            LabeledContent("Name") {
                TextField("Name", text: $editingConfig.characters[index].name)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Personality") {
                TextEditor(text: $editingConfig.characters[index].personality)
                    .frame(height: 50)
                    .border(.tertiary)
            }

            LabeledContent("Speech Style") {
                TextEditor(text: $editingConfig.characters[index].speechStyle)
                    .frame(height: 50)
                    .border(.tertiary)
            }

            LabeledContent("Voice ID") {
                TextField("Voice ID", text: $editingConfig.characters[index].voiceID)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Avatar") {
                HStack {
                    Text(editingConfig.characters[index].avatarPath ?? "No avatar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose...") {
                        chooseAvatar(for: index)
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func chooseAvatar(for index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            editingConfig.characters[index].avatarPath = url.path
        }
    }

    // MARK: - Connection Tab

    private var connectionTab: some View {
        Form {
            Section("LLM Provider") {
                Picker("Provider", selection: $editingConfig.llmProvider) {
                    ForEach(LLMProvider.allCases, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                switch editingConfig.llmProvider {
                case .groq:
                    SecureField("Groq API Key", text: $editingConfig.groqApiKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $editingConfig.groqModel)
                        .textFieldStyle(.roundedBorder)
                    Text("Get a free key at console.groq.com")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                case .ollama:
                    TextField("URL", text: $editingConfig.ollamaURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $editingConfig.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Circle()
                        .fill(engine.llmAvailable ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(engine.llmAvailable ? "Connected" : "Not reachable")
                        .font(.caption)
                }
            }

            Section("TTS Provider") {
                Picker("Provider", selection: $editingConfig.ttsProvider) {
                    ForEach(TTSProvider.allCases, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }

                if editingConfig.ttsProvider == .fishAudio {
                    SecureField("Fish Audio API Key", text: $editingConfig.fishAudioApiKey)
                        .textFieldStyle(.roundedBorder)
                    Text("Get a key at fish.audio — $15/M chars, zero-shot voice cloning")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if editingConfig.ttsProvider == .cartesia {
                    SecureField("Cartesia API Key", text: $editingConfig.cartesiaApiKey)
                        .textFieldStyle(.roundedBorder)
                    Text("Get a key at play.cartesia.ai — built-in voices (free tier)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Toggle("Enable TTS", isOn: $editingConfig.ttsEnabled)

                HStack {
                    Text("Speed")
                    Slider(value: $editingConfig.ttsSpeed, in: 0.5...2.0, step: 0.1)
                    Text(String(format: "%.1fx", editingConfig.ttsSpeed))
                        .monospacedDigit()
                }

                HStack {
                    Circle()
                        .fill(engine.ttsReady ? .green : engine.ttsStarting ? .yellow : .red)
                        .frame(width: 8, height: 8)
                    Text(engine.ttsReady ? "Ready" : engine.ttsStarting ? "Starting..." : "Not running")
                        .font(.caption)

                    Spacer()

                    Button(engine.ttsStarting ? "Starting..." : "Restart TTS") {
                        engine.restartTTS()
                    }
                    .disabled(engine.ttsStarting)
                    .font(.caption)
                }
            }

            Section("Buffering") {
                HStack {
                    Text("Buffer Duration")
                    Slider(value: $editingConfig.bufferDuration, in: 3...30, step: 1)
                    Text("\(Int(editingConfig.bufferDuration))s")
                        .monospacedDigit()
                }
            }
        }
        .padding()
    }
}
