import Foundation
import CoreAudio
import AudioToolbox
import os

private let logger = Logger.speaky(category: "AudioControlService")

final class AudioControlService: @unchecked Sendable {
    private var previousVolume: Float32?
    private var wasMuted = false

    func mute() {
        guard let deviceID = defaultOutputDevice() else { return }
        previousVolume = getVolume(deviceID)
        wasMuted = getMuteState(deviceID)
        setMuteState(deviceID, muted: true)
    }

    func unmute() {
        guard let deviceID = defaultOutputDevice() else { return }
        if !wasMuted {
            setMuteState(deviceID, muted: false)
        }
        if let vol = previousVolume {
            setVolume(deviceID, volume: vol)
        }
        previousVolume = nil
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func getVolume(_ deviceID: AudioDeviceID) -> Float32 {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        if status != noErr {
            logger.warning("Failed to get volume for device \(deviceID): OSStatus \(status)")
        }
        return volume
    }

    private func setVolume(_ deviceID: AudioDeviceID, volume: Float32) {
        var vol = volume
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        if status != noErr {
            logger.warning("Failed to set volume for device \(deviceID): OSStatus \(status)")
        }
    }

    private func getMuteState(_ deviceID: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        if status != noErr {
            logger.warning("Failed to get mute state for device \(deviceID): OSStatus \(status)")
        }
        return muted != 0
    }

    private func setMuteState(_ deviceID: AudioDeviceID, muted: Bool) {
        var val: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
        if status != noErr {
            logger.warning("Failed to set mute state for device \(deviceID): OSStatus \(status)")
        }
    }

    // MARK: - Input Device Enumeration

    struct AudioDeviceInfo: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
    }

    /// Find the built-in microphone by checking device transport type.
    /// Returns nil if no built-in input device is found (e.g. Mac Pro with no built-in mic).
    static func builtInInputDevice() -> AudioDeviceInfo? {
        for device in inputDevices() {
            var transportType: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &transportType) == noErr {
                if transportType == kAudioDeviceTransportTypeBuiltIn {
                    return device
                }
            }
        }
        return nil
    }

    static func inputDevices() -> [AudioDeviceInfo] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)

        return deviceIDs.compactMap { id -> AudioDeviceInfo? in
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var propSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &inputAddress, 0, nil, &propSize)

            let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(propSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufferListPtr.deallocate() }
            AudioObjectGetPropertyData(id, &inputAddress, 0, nil, &propSize, bufferListPtr)

            let bufferList = bufferListPtr.assumingMemoryBound(to: AudioBufferList.self).pointee
            guard bufferList.mNumberBuffers > 0 else { return nil }

            // Get device name
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
            return AudioDeviceInfo(id: id, name: name as String)
        }
    }
}
