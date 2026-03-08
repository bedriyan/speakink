import Foundation
import AVFoundation
import os

private let logger = Logger.speaky(category: "AudioRecorder")

final class AudioRecorder: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var levelMonitor: AudioLevelMonitor?
    private let lock = NSLock()

    static let sampleRate: Double = 16000
    private static let channels: AVAudioChannelCount = 1

    func start(deviceID: UInt32?, levelMonitor: AudioLevelMonitor?) throws {
        // Stop any previously running engine to prevent file descriptor leaks
        if audioEngine != nil {
            logger.warning("start() called while engine already running — stopping previous engine")
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine = nil
            lock.lock()
            audioFile = nil
            self.levelMonitor = nil
            lock.unlock()
        }

        self.levelMonitor = levelMonitor

        let engine = AVAudioEngine()

        // Set input device if specified, with validation and fallback
        if let deviceID {
            // Verify the device still exists before trying to set it
            let availableDevices = AudioControlService.inputDevices()
            let deviceExists = availableDevices.contains { $0.id == deviceID }

            if deviceExists {
                let inputNode = engine.inputNode
                var deviceIDVar = deviceID
                let size = UInt32(MemoryLayout<AudioDeviceID>.size)
                let status = AudioUnitSetProperty(
                    inputNode.audioUnit!,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceIDVar, size
                )
                if status != noErr {
                    logger.warning("Failed to set device \(deviceID) (status \(status)) — falling back to system default")
                    // Fall through to use system default
                }
            } else {
                logger.warning("Selected device \(deviceID) not available — using system default")
            }
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Validate the input format — some devices report 0 channels or 0 sample rate
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.failedToSetFormat(0)
        }

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: false
        ) else {
            throw AudioRecorderError.failedToSetFormat(0)
        }

        // Create output file
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("speaky_\(UUID().uuidString).wav")
        outputURL = url
        audioFile = try AVAudioFile(forWriting: url, settings: targetFormat.settings)

        // Install a converter tap if sample rates differ
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.failedToSetFormat(0)
        }

        inputNode.installTap(onBus: 0, bufferSize: Constants.Audio.bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Convert to target format
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * Self.sampleRate / inputFormat.sampleRate
            )
            guard frameCapacity > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                return
            }

            var error: NSError?
            var inputConsumed = false
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil else {
                logger.error("Audio converter error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                return
            }

            // Thread-safe access to audioFile and levelMonitor
            self.lock.lock()
            let file = self.audioFile
            let monitor = self.levelMonitor
            self.lock.unlock()

            // Write to file
            if let file {
                do {
                    try file.write(from: convertedBuffer)
                } catch {
                    logger.error("Failed to write audio buffer: \(error.localizedDescription, privacy: .public)")
                }
            }

            // Feed level monitor
            if let channelData = convertedBuffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
                monitor?.process(samples: samples)
            }
        }

        try engine.start()
        audioEngine = engine
        logger.info("Recording started — device: \(deviceID.map { String($0) } ?? "default", privacy: .public), sampleRate: \(inputFormat.sampleRate)")
    }

    func stop() throws -> URL {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        lock.lock()
        audioFile = nil
        levelMonitor = nil
        lock.unlock()

        guard let url = outputURL else {
            throw AudioRecorderError.noOutputURL
        }
        outputURL = nil

        // Verify file exists and has content
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? UInt64 ?? 0
        guard size > 44 else {
            logger.warning("Recording file too small (\(size) bytes) — treating as empty")
            throw AudioRecorderError.noOutputURL
        }

        logger.info("Recording stopped — file size: \(size) bytes")
        return url
    }
}

enum AudioRecorderError: LocalizedError {
    case failedToSetFormat(OSStatus)
    case noOutputURL

    var errorDescription: String? {
        switch self {
        case .failedToSetFormat(let s): "Failed to set format: \(s)"
        case .noOutputURL: "No output URL"
        }
    }
}
