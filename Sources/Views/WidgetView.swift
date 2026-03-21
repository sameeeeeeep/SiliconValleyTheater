import SwiftUI

// MARK: - WidgetView

/// Compact floating widget — shows current speaker, dialogue, status, and mini controls.
struct WidgetView: View {
    @Environment(TheaterEngine.self) private var engine
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Status bar (always visible)
            statusBar

            // Current line or idle
            if let line = engine.currentLine {
                activeLine(line)
            } else {
                idleState
            }

            // Last 2 transcript lines (compact)
            if !engine.dialogueHistory.isEmpty {
                recentLines
            }

            // Controls on hover
            if isHovered {
                miniControls
                    .transition(.opacity)
            }
        }
        .frame(width: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)
        .onHover { isHovered = $0 }
        .focusEffectDisabled()
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.spring(response: 0.3), value: engine.currentLine?.id)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            // Phase dot
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
                .shadow(color: statusColor.opacity(0.6), radius: 2)

            Text(engine.phase.rawValue)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))

            Spacer()

            // Session name
            if let path = engine.watcher.currentSessionFile {
                let project = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                    .replacingOccurrences(of: "-Users-sameeprehlan-", with: "")
                    .replacingOccurrences(of: "-", with: "/")
                    .suffix(20)
                Text(project)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }

            // Event count
            if engine.eventLog.count > 0 {
                Text("\(engine.eventLog.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Active Line

    private func activeLine(_ line: DialogueLine) -> some View {
        let idx = min(line.characterIndex, engine.config.characters.count - 1)
        let char = engine.config.characters[idx]
        let accent: Color = line.characterIndex == 0 ? .cyan : .green

        return HStack(spacing: 10) {
            // Talking indicator
            ZStack {
                Circle()
                    .fill(accent.opacity(0.15))
                Text(String(char.name.prefix(1)))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(accent.opacity(0.4), lineWidth: 1.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(char.name)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)

                Text(line.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Recent Lines

    private var recentLines: some View {
        let recent = engine.dialogueHistory.suffix(2)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(recent)) { line in
                let idx = min(line.characterIndex, engine.config.characters.count - 1)
                let name = engine.config.characters[idx].name
                let accent: Color = line.characterIndex == 0 ? .cyan : .green
                let isCurrent = line.id == engine.currentLine?.id

                if !isCurrent {
                    HStack(spacing: 4) {
                        Text(name)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(accent.opacity(0.5))
                        Text(line.text)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Idle State

    private var idleState: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.2))

            Text(activeThemeName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            Spacer()

            if engine.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Mini Controls

    private var miniControls: some View {
        HStack(spacing: 12) {
            // Play/Stop
            Button {
                if engine.phase == .idle { engine.start() } else { engine.stop() }
            } label: {
                Image(systemName: engine.phase == .idle ? "play.fill" : "pause.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)

            // Skip
            Button { engine.skipCurrentLine() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(engine.currentLine == nil ? 0.2 : 0.6))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .disabled(engine.currentLine == nil)

            // Refresh
            Button {
                engine.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { engine.start() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Spacer()

            // Demo
            Button { engine.demo() } label: {
                Text("Demo")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Helpers

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
}
