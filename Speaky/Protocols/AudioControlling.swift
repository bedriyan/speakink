import Foundation

/// Abstraction over system audio mute/unmute for testability.
protocol AudioControlling: AnyObject {
    func mute()
    func unmute()
}

extension AudioControlService: AudioControlling {}
