import SwiftUI

// MARK: - CharacterPanelView

/// A single character's video call tile — FaceTime style.
struct CharacterPanelView: View {
    let character: CharacterConfig
    let isSpeaking: Bool
    let characterIndex: Int

    private var accent: Color { characterIndex == 0 ? .cyan : .green }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Avatar / placeholder fills the panel
            avatarContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom gradient + name
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    // Name
                    Text(character.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)

                    // Sound bars when speaking
                    if isSpeaking {
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { i in
                                SoundBar(index: i, isActive: true, color: accent)
                            }
                        }
                        .frame(width: 14, height: 12)
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .padding(.top, 40)
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
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSpeaking ? accent.opacity(0.5) : .white.opacity(0.06),
                    lineWidth: isSpeaking ? 2 : 0.5
                )
        )
        .shadow(
            color: isSpeaking ? accent.opacity(0.2) : .clear,
            radius: 12
        )
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarContent: some View {
        if let path = character.avatarPath,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: characterIndex == 0
                        ? [Color(hex: 0x0d1b2a), Color(hex: 0x1b2838)]
                        : [Color(hex: 0x0a1f14), Color(hex: 0x162d20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Text(String(character.name.prefix(1)))
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.08))
            }
        }
    }
}

// MARK: - Sound Bar

struct SoundBar: View {
    let index: Int
    let isActive: Bool
    var color: Color = .green

    @State private var height: CGFloat = 3

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2.5, height: height)
            .onAppear { animate() }
            .onChange(of: isActive) { _, _ in animate() }
    }

    private func animate() {
        if isActive {
            withAnimation(
                .easeInOut(duration: 0.3 + Double(index) * 0.1)
                .repeatForever(autoreverses: true)
                .delay(Double(index) * 0.08)
            ) {
                height = CGFloat.random(in: 5...11)
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) { height = 3 }
        }
    }
}
