import AVFoundation

// MARK: - AudioPlayer

/// Plays a single audio clip at a time. The engine drives sequencing.
@MainActor
@Observable
final class AudioPlayer {

    private(set) var isPlaying = false

    var masterVolume: Float = 0.8

    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?

    /// Play a single audio data clip. Calls onFinished when done.
    func playOnce(data: Data, onFinished: @escaping () -> Void) {
        stopAll()

        do {
            let audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer.volume = masterVolume

            let delegate = PlayerDelegate { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isPlaying = false
                    onFinished()
                }
            }
            audioPlayer.delegate = delegate
            self.playerDelegate = delegate

            audioPlayer.prepareToPlay()
            audioPlayer.play()

            player = audioPlayer
            isPlaying = true
        } catch {
            debugLog("[Audio] Playback error: \(error)")
            onFinished()
        }
    }

    func stopAll() {
        player?.stop()
        player = nil
        playerDelegate = nil
        isPlaying = false
    }
}

// MARK: - PlayerDelegate

private class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        onFinished()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinished()
    }
}
