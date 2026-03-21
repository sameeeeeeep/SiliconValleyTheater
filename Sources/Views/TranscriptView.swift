import SwiftUI

// MARK: - TranscriptView

/// Left-aligned chat transcript — all messages flow top to bottom.
struct TranscriptView: View {
    @Environment(TheaterEngine.self) private var engine

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(engine.dialogueHistory) { line in
                        chatLine(line)
                            .id(line.id)
                    }
                }
                .padding(10)
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
        let idx = min(line.characterIndex, engine.config.characters.count - 1)
        let name = engine.config.characters[idx].name
        let accent: Color = line.characterIndex == 0 ? .cyan : .green
        let isCurrent = engine.currentLine?.id == line.id

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 60, alignment: .trailing)

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
