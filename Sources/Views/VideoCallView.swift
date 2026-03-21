import SwiftUI

// MARK: - VideoCallView

/// Two character panels side-by-side in a video call layout.
struct VideoCallView: View {
    @Environment(TheaterEngine.self) private var engine

    var body: some View {
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
    }
}
