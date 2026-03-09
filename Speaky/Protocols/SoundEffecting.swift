import Foundation

/// Abstraction over sound effect playback for testability.
@MainActor
protocol SoundEffecting: AnyObject {
    func playStartAndWait() async
    func playEnd()
}

extension SoundEffectService: SoundEffecting {}
