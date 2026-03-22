import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @Environment(TheaterEngine.self) private var engine
    @AppStorage("main.showTranscript") private var showTranscript = false
    @State private var showSettings = false
    @State private var showSessionPicker = false
    @State private var isHoveringControls = false

    var body: some View {
        ZStack {
            // Full-bleed dark background
            Color(hex: 0x080810).ignoresSafeArea()

            // Video call fills entire window
            VideoCallView()
                .ignoresSafeArea()

            // Overlays on top
            VStack(spacing: 0) {
                // Top: minimal info
                topOverlay
                    .padding(.top, 12)
                    .padding(.horizontal, 16)

                Spacer()

                // Subtitle (above controls)
                if let line = engine.currentLine {
                    SubtitleOverlay(line: line, characters: engine.config.characters)
                        .padding(.horizontal, 40)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }

                // Transcript panel (collapsible)
                if showTranscript {
                    TranscriptView()
                        .frame(maxHeight: 160)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Bottom: FaceTime-style floating controls
                controlBar
                    .padding(.bottom, 16)
                    .padding(.top, 10)
            }
        }
        .focusEffectDisabled()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: engine.currentLine?.id)
        .animation(.easeInOut(duration: 0.2), value: showTranscript)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(engine)
                .frame(minWidth: 520, minHeight: 500)
        }
        .onKeyPress(.space) {
            if engine.phase == .idle { engine.start() } else { engine.stop() }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            engine.skipCurrentLine()
            return .handled
        }
    }

    // MARK: - Top Overlay

    private var topOverlay: some View {
        HStack {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .shadow(color: statusColor.opacity(0.6), radius: 3)

            Text(engine.phase.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))

            if let err = engine.error {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(1)
            }

            Spacer()

            // Session picker
            Button {
                engine.watcher.refreshSessions()
                showSessionPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 9))
                    Text(currentSessionLabel)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(showSessionPicker ? 0.1 : 0.0), in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSessionPicker, arrowEdge: .top) {
                sessionPickerPopover
            }

            Spacer()

            if engine.eventLog.count > 0 {
                Text("\(engine.eventLog.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
    }

    // MARK: - Control Bar (FaceTime style)

    private var controlBar: some View {
        HStack(spacing: 16) {
            // Demo button (looks like mic unmute)
            Button {
                engine.demo()
            } label: {
                Image(systemName: engine.phase == .generating ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(engine.phase == .generating ? .green : .red.opacity(0.9))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Demo: generate test dialogue")

            // Pause / Resume
            Button {
                engine.togglePause()
            } label: {
                Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(engine.isPaused ? .yellow : .white.opacity(0.8))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(engine.isPaused ? .yellow.opacity(0.15) : .white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(engine.isPaused ? "Resume" : "Pause")
            .disabled(engine.phase == .idle)

            // Play / Stop
            Button {
                if engine.phase == .idle { engine.start() } else { engine.stop() }
            } label: {
                Image(systemName: engine.phase == .idle ? "play.fill" : "stop.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle().fill(engine.phase == .idle ? .green : .white.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)

            // Volume
            HStack(spacing: 4) {
                Image(systemName: engine.config.masterVolume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Slider(value: Bindable(engine).config.masterVolume, in: 0...1)
                    .frame(width: 60)
                    .controlSize(.mini)
            }

            // Skip
            Button { engine.skipCurrentLine() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(engine.currentLine == nil ? 0.2 : 0.8))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(engine.currentLine == nil)

            // Refresh — restart listening
            Button {
                engine.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    engine.start()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Refresh: restart listening")

            // Transcript toggle
            Button { showTranscript.toggle() } label: {
                Image(systemName: showTranscript ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 14))
                    .foregroundStyle(showTranscript ? .cyan : .white.opacity(0.8))
                    .frame(width: 42, height: 42)
                    .background(
                        Circle().fill(showTranscript ? .cyan.opacity(0.15) : .white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            // Settings
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            // End Call
            Button {
                engine.stop()
                engine.clearHistory()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.red))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 6)
    }

    // MARK: - Helpers

    private func controlButton(icon: String, tint: Color, size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(0.08)))
    }

    private var statusColor: Color {
        switch engine.phase {
        case .idle: .gray
        case .watching: .green
        case .buffering: .yellow
        case .generating: .blue
        case .synthesizing: .purple
        case .playing: .cyan
        }
    }

    private var activeThemeName: String {
        ThemeStore.shared.allThemes()
            .first { $0.id == engine.config.activeThemeId }?.name ?? "Theater"
    }

    private var currentSessionLabel: String {
        if let path = engine.watcher.currentSessionFile,
           let session = engine.watcher.availableSessions.first(where: { $0.path == path }) {
            return session.displayName
        } else if engine.watcher.currentSessionFile != nil {
            return "Active session"
        }
        return "No session"
    }

    private var sessionPickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Sessions")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if engine.watcher.pinnedSession != nil {
                    Button("Auto") {
                        engine.watcher.pinSession(nil)
                        showSessionPicker = false
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            let sessions = engine.watcher.availableSessions
            if sessions.isEmpty {
                Text("No active sessions found")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .frame(maxHeight: 250)
            }
        }
        .frame(width: 280)
        .background(.ultraThickMaterial)
    }

    private func sessionRow(_ session: SessionWatcher.SessionInfo) -> some View {
        let isCurrent = engine.watcher.currentSessionFile == session.path
        let isPinned = engine.watcher.pinnedSession == session.path
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let ago = formatter.localizedString(for: session.lastModified, relativeTo: Date())

        return Button {
            engine.watcher.pinSession(session.path)
            showSessionPicker = false
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isCurrent ? .green : .gray.opacity(0.3))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .lineLimit(1)

                    Text("\(ago) · \(session.sizeKB) KB")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isCurrent ? Color.accentColor.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
