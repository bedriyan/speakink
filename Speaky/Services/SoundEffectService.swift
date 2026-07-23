import AVFoundation
import os

@MainActor
final class SoundEffectService {
    private var startPlayer: AVAudioPlayer?
    private var endPlayer: AVAudioPlayer?
    private static let logger = Logger.speaky(category: "SoundEffect")

    /// Play start sound and wait for it to finish before returning.
    func playStartAndWait() async {
        guard let url = Bundle.main.url(forResource: "start", withExtension: "m4a", subdirectory: "Sounds") else {
            Self.logger.warning("Sound file not found: start.m4a")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            startPlayer?.stop()
            startPlayer = player
            player.volume = 0.15
            player.prepareToPlay()

            guard player.play() else {
                Self.logger.warning("Failed to start playback: start.m4a")
                startPlayer = nil
                return
            }

            defer {
                if startPlayer === player {
                    startPlayer = nil
                }
            }

            // Wait for the sound to finish so caller can mute after
            do {
                try await Task.sleep(for: .seconds(player.duration))
            } catch {
                player.stop()
            }
        } catch {
            Self.logger.warning("Failed to play start sound: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopStart() {
        startPlayer?.stop()
        startPlayer = nil
    }

    func playEnd() {
        guard let url = Bundle.main.url(forResource: "end", withExtension: "m4a", subdirectory: "Sounds") else {
            Self.logger.warning("Sound file not found: end.m4a")
            return
        }
        do {
            endPlayer = try AVAudioPlayer(contentsOf: url)
            endPlayer?.volume = 0.15
            endPlayer?.play()
        } catch {
            Self.logger.warning("Failed to play end sound: \(error.localizedDescription, privacy: .public)")
        }
    }
}
