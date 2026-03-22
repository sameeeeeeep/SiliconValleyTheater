import SwiftUI

@main
struct SiliconValleyApp: App {
    @State private var engine = TheaterEngine()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Widget is the default window — compact floating panel
        WindowGroup {
            WidgetView()
                .environment(engine)
                .background(FloatingPanelConfigurator())
                .task {
                    if engine.phase == .idle {
                        engine.start()
                    }
                    appDelegate.engine = engine
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 280)
        .defaultPosition(.topTrailing)

        // Main window — full video call view (open from menu bar)
        Window("SiliconValley Theater", id: "main") {
            ContentView()
                .environment(engine)
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 720)

        // Settings
        Settings {
            SettingsView()
                .environment(engine)
        }

        // Menu bar extra — TV icon in the top menu bar
        MenuBarExtra {
            MenuBarContentView()
                .environment(engine)
        } label: {
            Image(systemName: "theatermasks.fill")
        }
    }
}

// MARK: - Floating Panel Configurator

/// Makes the widget window float above all others (like a panel).
struct FloatingPanelConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.level = .floating
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                // Compact size for widget
                window.setContentSize(NSSize(width: 520, height: 280))
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - App Delegate (for managing windows)

class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: TheaterEngine?
}

// MARK: - Menu Bar Content

struct MenuBarContentView: View {
    @Environment(TheaterEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(engine.phase.rawValue)
                    .font(.headline)
            }

            if let line = engine.currentLine {
                let idx = min(line.characterIndex, engine.config.characters.count - 1)
                Text("\(engine.config.characters[idx].name): \(line.text)")
                    .font(.caption)
                    .lineLimit(2)
            }

            Divider()

            // Controls
            if engine.phase == .idle {
                Button("Start Watching") { engine.start() }
            } else {
                Button("Stop") { engine.stop() }
            }

            if engine.phase != .idle {
                Button(engine.isPaused ? "Resume" : "Pause") {
                    engine.togglePause()
                }
                .keyboardShortcut("p")
            }

            Button("Refresh") {
                engine.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    engine.start()
                }
            }
            .keyboardShortcut("r")

            Button("Demo") { engine.demo() }

            Divider()

            Button("Open Main Window") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")

            Button("Settings...") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",")

            Divider()

            // Debug log shortcut
            Button("Open Debug Log") {
                let logPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".siliconvalley/debug.log").path
                NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }

    private var statusColor: Color {
        switch engine.phase {
        case .idle: .gray
        case .watching: .blue
        case .buffering: .yellow
        case .generating: .orange
        case .synthesizing: .purple
        case .playing: .green
        }
    }
}
