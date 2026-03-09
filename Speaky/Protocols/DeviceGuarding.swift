import CoreAudio

/// Abstraction over audio device monitoring for testability.
protocol DeviceGuarding: AnyObject {
    var onDeviceLost: (() -> Void)? { get set }
    func lock(to deviceID: AudioDeviceID)
    func unlock()
}

extension DeviceGuard: DeviceGuarding {}
