import Foundation

/// Abstraction over audio recording for testability.
protocol AudioRecording: AnyObject {
    func start(deviceID: UInt32?, levelMonitor: AudioLevelMonitor?) throws
    func stop() throws -> URL
}

extension AudioRecorder: AudioRecording {}
