import Foundation

/// Abstraction over media playback control for testability.
protocol PlaybackControlling: AnyObject {
    func pause()
    func resume()
}

extension PlaybackController: PlaybackControlling {}
