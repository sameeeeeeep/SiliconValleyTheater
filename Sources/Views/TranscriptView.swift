import SwiftUI

// MARK: - TranscriptView

/// Left-aligned chat transcript — all messages flow top to bottom.
struct TranscriptView: View {
    @Environment(TheaterEngine.self) private var engine
    @State private var isUserScrolling = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if engine.dialogueHistory.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.15))
                        Text("Transcript will appear here")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .padding(.vertical, 20)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(engine.dialogueHistory) { line in
                            chatLine(line)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
            }
            .onChange(of: engine.dialogueHistory.count) { _, _ in
                if let last = engine.dialogueHistory.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func chatLine(_ line: DialogueLine) -> some View {
        let chars = engine.config.characters
        let name: String
        let accent: Color
        if chars.isEmpty {
            name = "Speaker"
            accent = .cyan
        } else {
            let idx = min(line.characterIndex, chars.count - 1)
            name = chars[idx].name
            accent = line.characterIndex == 0 ? .cyan : .green
        }
        let isCurrent = engine.currentLine?.id == line.id

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 70, alignment: .trailing)

            Text(line.text)
                .font(.system(size: 11))
                .foregroundStyle(isCurrent ? .white : .white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? accent.opacity(0.08) : .clear)
        )
    }
}
