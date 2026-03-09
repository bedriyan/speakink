import Foundation
import CoreAudio
import os

private let logger = Logger.speaky(category: "DeviceGuard")

/// Monitors a locked audio input device via CoreAudio HAL listeners.
/// When the locked device is physically disconnected (USB/Bluetooth removal),
/// fires `onDeviceLost` so the recording can be gracefully stopped.
final class DeviceGuard: @unchecked Sendable {
    private var lockedDeviceID: AudioDeviceID?
    private var isListening = false
    var onDeviceLost: (() -> Void)?

    // Stored as a property so it can be removed later
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// Lock monitoring to a specific audio input device.
    func lock(to deviceID: AudioDeviceID) {
        unlock() // Clean up any previous listener
        lockedDeviceID = deviceID
        startListening()
        logger.info("DeviceGuard locked to device \(deviceID)")
    }

    /// Stop monitoring. Safe to call multiple times.
    func unlock() {
        stopListening()
        lockedDeviceID = nil
    }

    /// Check if the locked device is still present in the system's device list.
    func isLockedDeviceAvailable() -> Bool {
        guard let lockedID = lockedDeviceID else { return false }
        let devices = AudioControlService.inputDevices()
        return devices.contains { $0.id == lockedID }
    }

    // MARK: - Private

    private func startListening() {
        guard !isListening else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Check if our locked device is still available
            if !self.isLockedDeviceAvailable() {
                logger.warning("Locked audio device \(self.lockedDeviceID ?? 0) disconnected")
                DispatchQueue.main.async {
                    self.onDeviceLost?()
                }
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )

        if status == noErr {
            listenerBlock = block
            isListening = true
        } else {
            logger.error("Failed to add device listener: \(status)")
        }
    }

    private func stopListening() {
        guard isListening, let block = listenerBlock else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )

        listenerBlock = nil
        isListening = false
    }

    deinit {
        stopListening()
    }
}
