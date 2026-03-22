import SwiftUI

// MARK: - VideoCallView

/// Two character panels side-by-side in a video call layout,
/// with a small "Richard" (user) tile in the corner — FaceTime self-view style.
struct VideoCallView: View {
    @Environment(TheaterEngine.self) private var engine

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Main character panels
            HStack(spacing: 10) {
                if engine.config.characters.count >= 2 {
                    CharacterPanelView(
                        character: engine.config.characters[0],
                        isSpeaking: engine.currentSpeaker == 0,
                        characterIndex: 0
                    )

                    CharacterPanelView(
                        character: engine.config.characters[1],
                        isSpeaking: engine.currentSpeaker == 1,
                        characterIndex: 1
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // You (Richard) — small floating card, bottom-right
            UserPanelView(
                latestMessage: engine.latestUserMessage,
                latestMessageTime: engine.latestUserMessageTime
            )
            .frame(width: 140, height: 100)
            .padding(14)
        }
    }
}

// MARK: - User Panel View ("Richard")

/// Small self-view tile for the user, FaceTime PiP style.
struct UserPanelView: View {
    let latestMessage: String?
    let latestMessageTime: Date?

    private var isRecent: Bool {
        guard let time = latestMessageTime else { return false }
        return Date().timeIntervalSince(time) < 8
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Avatar or fallback
            if let path = TheaterConfig.userAvatarPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: 0x1a1020), Color(hex: 0x261430)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text("R")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.08))
                }
            }

            // Bottom gradient + name
            VStack {
                Spacer()

                // Message preview
                if let msg = latestMessage, isRecent {
                    Text(msg)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .transition(.opacity)
                }

                HStack(spacing: 5) {
                    Text("You (Richard)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)

                    if isRecent {
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { i in
                                SoundBar(index: i, isActive: true, color: .purple)
                            }
                        }
                        .frame(width: 14, height: 12)
                    }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .padding(.top, 20)
                .background(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.6), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isRecent ? Color.purple.opacity(0.5) : .white.opacity(0.1),
                    lineWidth: isRecent ? 2 : 0.5
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 8)
        .animation(.easeInOut(duration: 0.3), value: isRecent)
    }
}
