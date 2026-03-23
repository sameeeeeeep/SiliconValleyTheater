import SwiftUI

// MARK: - WidgetView

/// Multi-room floating widget — Zoom meeting rooms style.
/// Left sidebar shows all active sessions as "rooms".
/// Right side shows the selected room's video call view.
struct WidgetView: View {
    @Environment(TheaterEngine.self) private var engine
    @State private var isHovered = false
    @AppStorage("widget.showRooms") private var showRooms = true

    var body: some View {
        VStack(spacing: 0) {
            // Top bar — meeting info + room toggle
            topBar

            // Main content: room list + active room view
            HStack(spacing: 0) {
                // Room list sidebar (collapsible)
                if showRooms {
                    roomSidebar
                        .frame(width: 160)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                // Active room — video tiles + subtitle
                VStack(spacing: 0) {
                    videoTiles
                        .frame(height: 160)

                    subtitleArea
                        .frame(minHeight: 52)
                }
            }

            // Bottom toolbar — Zoom-style controls (always show on hover)
            if isHovered {
                bottomToolbar
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: showRooms ? 520 : 340)
        .background(Color(hex: 0x1A1A1F, alpha: 0.91))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.31), radius: 20, x: 0, y: 6)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 1)
        .onHover { isHovered = $0 }
        .focusEffectDisabled()
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: showRooms)
        .animation(.spring(response: 0.3), value: engine.currentLine?.id)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            // Refresh user tile "isRecent" state periodically
            if engine.latestUserMessageTime != nil {
                userTileTick.toggle()
            }
        }
        .onKeyPress(.space) {
            if engine.phase == .idle { engine.start() } else { engine.togglePause() }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            engine.skipCurrentLine()
            return .handled
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 6) {
            // Green "secure" lock icon like Zoom
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
                .foregroundStyle(.green.opacity(0.5))

            Text(activeThemeName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            // Recording indicator
            if engine.phase == .playing || engine.phase == .synthesizing {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .modifier(PulseModifier())
                    Text("LIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.red.opacity(0.8))
                }
            }

            Spacer().frame(width: 8)

            // Room list toggle
            Button {
                engine.watcher.refreshSessions()
                showRooms.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 8))
                    let count = engine.watcher.availableSessions.prefix(10).count
                    Text("\(count) rooms")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 11).fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(hex: 0x232326))
    }

    // MARK: - Room Sidebar

    private var roomSidebar: some View {
        let sessions = Array(engine.watcher.availableSessions.prefix(12))
        let themes = ThemeStore.shared.allThemes()

        return VStack(spacing: 0) {
            // Header
            HStack {
                Text("ROOMS")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.25))
                    .tracking(1.5)
                Spacer()
                Text("\(sessions.count)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.06)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sessions) { session in
                        roomCard(session: session, themes: themes)
                    }

                    if sessions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.slash.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.12))
                            Text("No active sessions")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)

            // Auto-follow toggle
            if engine.watcher.pinnedSession != nil {
                Button {
                    engine.watcher.pinSession(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "autostartstop")
                            .font(.system(size: 8))
                        Text("Auto-follow")
                            .font(.system(size: 8, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(.blue.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(hex: 0x141416))
    }

    private func roomCard(session: SessionWatcher.SessionInfo, themes: [CharacterTheme]) -> some View {
        let isCurrent = engine.watcher.currentSessionFile == session.path
        let themeId = engine.config.themeId(forSession: session.path)
        let theme = themes.first(where: { $0.id == themeId })
        let isActive = isSessionActive(session)
        let characters = theme?.characters ?? []
        let charNames = characters.map(\.name).joined(separator: " & ")

        return Button {
            engine.selectRoom(session.path)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Top row — project name + status
                HStack(spacing: 6) {
                    Circle()
                        .fill(isCurrent ? Color.green : (isActive ? Color.blue.opacity(0.6) : Color.gray.opacity(0.25)))
                        .frame(width: 6, height: 6)

                    Text(session.displayName)
                        .font(.system(size: 10, weight: isCurrent ? .bold : .semibold))
                        .foregroundStyle(isCurrent ? .white : .white.opacity(0.6))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }

                // Character avatars row
                HStack(spacing: -4) {
                    ForEach(Array(characters.prefix(2).enumerated()), id: \.offset) { i, char in
                        Text(String(char.name.prefix(1)))
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 18, height: 18)
                            .background(
                                Circle().fill(
                                    i == 0
                                        ? Color(hex: 0x1b2838)
                                        : Color(hex: 0x162d20)
                                )
                            )
                            .overlay(Circle().strokeBorder(Color(hex: 0x1A1A1F), lineWidth: 1.5))
                    }

                    // Theme name
                    Button {
                        engine.cycleRoomTheme(forSession: session.path)
                    } label: {
                        Text(charNames.isEmpty ? "—" : charNames)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(isCurrent ? .cyan.opacity(0.7) : .white.opacity(0.3))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCurrent ? Color.white.opacity(0.07) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isCurrent ? Color.green.opacity(0.2) : .clear,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func isSessionActive(_ session: SessionWatcher.SessionInfo) -> Bool {
        session.lastModified.timeIntervalSinceNow > -300
    }

    // MARK: - Video Tiles

    private var videoTiles: some View {
        ZStack(alignment: .bottomTrailing) {
            // Two main character tiles
            HStack(spacing: 3) {
                if engine.config.characters.count >= 2 {
                    characterTile(
                        char: engine.config.characters[0],
                        index: 0,
                        isSpeaking: engine.currentSpeaker == 0
                    )
                    characterTile(
                        char: engine.config.characters[1],
                        index: 1,
                        isSpeaking: engine.currentSpeaker == 1
                    )
                }
            }

            // "You (Richard)" — small floating card, bottom-right
            userTile
                .frame(width: 66, height: 44)
                .padding(6)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    // MARK: - User Tile ("Richard")

    // Timer to refresh user tile "isRecent" state
    @State private var userTileTick = false

    private var userTile: some View {
        // userTileTick forces SwiftUI to re-evaluate isRecent when the timer fires
        let _ = userTileTick
        let isRecent: Bool = {
            guard let time = engine.latestUserMessageTime else { return false }
            return Date().timeIntervalSince(time) < 8
        }()

        return ZStack(alignment: .bottom) {
            // Background — avatar or fallback gradient
            if let path = TheaterConfig.userAvatarPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Color(hex: 0x1a1020), Color(hex: 0x261430)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(
                    Text("R")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.06))
                )
            }

            // Bottom bar — name + mic
            HStack(spacing: 3) {
                if isRecent {
                    HStack(spacing: 1) {
                        ForEach(0..<3, id: \.self) { i in
                            SoundBar(index: i, isActive: true, color: .white)
                        }
                    }
                    .frame(width: 10, height: 8)
                } else {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Text("You (\(activeUserName))")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.8), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isRecent ? Color.purple.opacity(0.6) : .clear,
                    lineWidth: isRecent ? 1.5 : 0
                )
        )
        .animation(.easeInOut(duration: 0.3), value: isRecent)
    }

    private func characterTile(char: CharacterConfig, index: Int, isSpeaking: Bool) -> some View {
        let accent: Color = index == 0 ? .cyan : .green

        return ZStack(alignment: .bottom) {
            // Background gradient
            if let path = char.avatarPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: index == 0
                        ? [Color(hex: 0x0d1b2a), Color(hex: 0x1b2838)]
                        : [Color(hex: 0x0a1f14), Color(hex: 0x162d20)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay(
                    Text(String(char.name.prefix(1)))
                        .font(.system(size: 48, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.03))
                )
            }

            // Bottom bar — name + mic indicator
            HStack(spacing: 5) {
                if isSpeaking {
                    HStack(spacing: 1.5) {
                        ForEach(0..<3, id: \.self) { i in
                            SoundBar(index: i, isActive: true, color: .white)
                        }
                    }
                    .frame(width: 14, height: 12)
                } else {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Text(char.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.8), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSpeaking ? accent.opacity(0.4) : .clear,
                    lineWidth: isSpeaking ? 1.5 : 0
                )
        )
    }

    // MARK: - Subtitle Area

    private var subtitleArea: some View {
        ZStack {
            Color(hex: 0x111114)

            if let line = engine.currentLine {
                let idx = min(line.characterIndex, engine.config.characters.count - 1)
                let char = engine.config.characters[idx]
                let accent: Color = line.characterIndex == 0 ? .cyan : .green

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(accent)
                            .frame(width: 5, height: 5)
                        Text(char.name)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(accent)
                        Spacer()
                    }

                    Text(line.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineSpacing(3)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)
            } else if let err = engine.error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(err.prefix(60))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
            } else if engine.needsSetup {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow.opacity(0.8))
                    Text(engine.config.llmProvider == .groq
                        ? "Add your Groq API key in Settings to get started"
                        : "Ollama not reachable — run 'ollama serve' first")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                .padding(.horizontal, 12)
            } else if engine.watcher.availableSessions.isEmpty && engine.phase == .idle {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.2))
                    Text("No Claude Code sessions found. Start one to begin.")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 12)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.15))
                    Text(engine.isPaused ? "Paused" : (engine.phase == .idle ? "Ready" : engine.phase.rawValue))
                        .font(.system(size: 10))
                        .foregroundStyle(engine.isPaused ? .yellow.opacity(0.6) : .white.opacity(0.3))
                    Spacer()
                }
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - Bottom Toolbar (Zoom-style)

    private var bottomToolbar: some View {
        VStack(spacing: 0) {
            // Separator line
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: 0) {
                // Left controls group
                HStack(spacing: 6) {
                    // Mic button
                    toolbarIconButton(
                        icon: "mic.fill",
                        isActive: engine.phase != .idle
                    ) {
                        if engine.phase == .idle { engine.start() } else { engine.stop() }
                    }

                    // Pause button
                    toolbarIconButton(
                        icon: engine.isPaused ? "play.fill" : "pause.fill",
                        isActive: !engine.isPaused && engine.phase != .idle
                    ) {
                        engine.togglePause()
                    }
                    .opacity(engine.phase == .idle ? 0.3 : 1.0)

                    // Skip button
                    toolbarIconButton(
                        icon: "forward.fill",
                        isActive: engine.currentLine != nil
                    ) {
                        engine.skipCurrentLine()
                    }
                    .opacity(engine.currentLine == nil ? 0.3 : 1.0)

                    // Volume
                    HStack(spacing: 4) {
                        Image(systemName: engine.config.masterVolume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                        Slider(value: Bindable(engine).config.masterVolume, in: 0...1)
                            .frame(width: 40)
                            .controlSize(.mini)
                    }
                }

                Spacer()

                // End button
                Button {
                    engine.stop()
                } label: {
                    Text("End")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(Capsule().fill(Color(hex: 0xFF3B30)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
        }
    }

    private func toolbarIconButton(icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var activeThemeName: String {
        ThemeStore.shared.allThemes()
            .first { $0.id == engine.config.activeThemeId }?.name ?? "Theater"
    }

    private var activeUserName: String {
        ThemeStore.shared.allThemes()
            .first { $0.id == engine.config.activeThemeId }?.userCharacterName ?? "You"
    }
}

// MARK: - Pulse Modifier

struct PulseModifier: ViewModifier {
    @State private var opacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    opacity = 0.3
                }
            }
    }
}
