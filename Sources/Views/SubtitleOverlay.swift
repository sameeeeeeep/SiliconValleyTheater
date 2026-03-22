import SwiftUI

// MARK: - SubtitleOverlay

/// Clean centered subtitle — like FaceTime captions.
struct SubtitleOverlay: View {
    let line: DialogueLine
    let characters: [CharacterConfig]

    @State private var appeared = false

    private var name: String {
        guard !characters.isEmpty else { return "Speaker" }
        let idx = min(line.characterIndex, characters.count - 1)
        return characters[idx].name
    }

    private var accent: Color {
        line.characterIndex == 0 ? .cyan : .green
    }

    var body: some View {
        HStack(spacing: 8) {
            // Colored dot
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)

            Text(name)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)

            Text(line.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { appeared = true }
        }
        .onChange(of: line.id) { _, _ in
            appeared = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { appeared = true }
        }
    }
}
