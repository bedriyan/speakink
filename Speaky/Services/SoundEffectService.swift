import AVFoundation
import os

@MainActor
final class SoundEffectService {
    private var startPlayer: AVAudioPlayer?
    private var endPlayer: AVAudioPlayer?
    private static let logger = Logger(subsystem: "com.bedriyan.speaky", category: "SoundEffect")

    /// Play start sound and wait for it to finish before returning.
    func playStartAndWait() async {
        guard let url = Bundle.main.url(forResource: "start", withExtension: "m4a", subdirectory: "Sounds") else {
            Self.logger.warning("Sound file not found: start.m4a")
            return
        }
        do {
            startPlayer = try AVAudioPlayer(contentsOf: url)
            startPlayer?.volume = 0.15
            startPlayer?.play()
            // Wait for the sound to finish so caller can mute after
            let duration = startPlayer?.duration ?? 2.0
            try? await Task.sleep(for: .seconds(duration))
        } catch {
            Self.logger.warning("Failed to play start sound: \(error.localizedDescription, privacy: .public)")
        }
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
