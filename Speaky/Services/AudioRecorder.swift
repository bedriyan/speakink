import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import os

private let logger = Logger.speaky(category: "AudioRecorder")

/// Records audio using CoreAudio HAL AudioUnit directly (not AVAudioEngine).
/// This gives us reliable device selection that isn't hijacked by Bluetooth
/// aggregate device routing — whatever device the user picks, it stays.
final class AudioRecorder: @unchecked Sendable {
    private var audioUnit: AudioUnit?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var levelMonitor: AudioLevelMonitor?
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.bedriyan.speaky.audioWrite", qos: .userInitiated)

    // Device and format state
    private var deviceFormat = AudioStreamBasicDescription()
    private var currentDeviceID: AudioDeviceID = 0

    // Pre-allocated buffers for the real-time audio callback (no malloc allowed)
    private var renderBuffer: UnsafeMutablePointer<Float32>?
    private var renderBufferSize: UInt32 = 0
    private var conversionBuffer: UnsafeMutablePointer<Float32>?
    private var conversionBufferSize: UInt32 = 0

    // Pre-allocated write buffer to avoid allocations per callback
    private var targetFormat: AVAudioFormat?
    private var writeBuffer: AVAudioPCMBuffer?

    static let sampleRate: Double = 16000
    private static let channels: AVAudioChannelCount = 1
    private static let maxFrames: UInt32 = 4096

    func start(deviceID: UInt32?, levelMonitor: AudioLevelMonitor?) throws {
        // Cleanup any previous session
        if audioUnit != nil {
            logger.warning("start() called while unit running — stopping previous")
            cleanupUnit()
            freeBuffers()
        }

        lock.lock()
        self.levelMonitor = levelMonitor
        lock.unlock()

        // 1. Create HAL Output AudioUnit (direct hardware access)
        try createAudioUnit()

        // 2. Set the input device — this is the key fix.
        //    Unlike AVAudioEngine, HAL AudioUnit respects our device choice
        //    and doesn't get overridden by Bluetooth aggregate devices.
        if let deviceID {
            let available = AudioControlService.inputDevices()
            if available.contains(where: { $0.id == deviceID }) {
                try setInputDevice(deviceID)
                currentDeviceID = deviceID
            } else {
                logger.warning("Device \(deviceID) unavailable — using system default")
            }
        }

        // 3. Configure audio formats and pre-allocate buffers
        try configureFormats()

        // 4. Set up the render callback
        try setupInputCallback()

        // 5. Create output WAV file (16kHz mono Float32)
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: false
        ) else {
            throw AudioRecorderError.failedToSetFormat(0)
        }
        targetFormat = fmt

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("speaky_\(UUID().uuidString).wav")
        outputURL = url
        audioFile = try AVAudioFile(forWriting: url, settings: fmt.settings)

        // Pre-allocate write buffer with max capacity
        let maxOutputFrames = UInt32(Double(Self.maxFrames) * (Self.sampleRate / deviceFormat.mSampleRate)) + 1
        writeBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: maxOutputFrames)

        // 6. Initialize and start the AudioUnit
        guard let unit = audioUnit else {
            throw AudioRecorderError.componentNotFound
        }

        var status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw AudioRecorderError.failedToInitialize(status)
        }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw AudioRecorderError.failedToStart(status)
        }

        // Log which device is actually active (confirmation)
        var activeDevice: AudioDeviceID = 0
        var verifySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &activeDevice, &verifySize
        )
        let deviceName = AudioControlService.inputDevices()
            .first { $0.id == activeDevice }?.name ?? "unknown"
        logger.info("Recording started — device: \(deviceName, privacy: .public) (id: \(activeDevice)), deviceRate: \(self.deviceFormat.mSampleRate), channels: \(self.deviceFormat.mChannelsPerFrame)")
    }

    func stop() throws -> URL {
        cleanupUnit()

        // Wait for any pending writes to flush
        writeQueue.sync {}

        lock.lock()
        audioFile = nil
        levelMonitor = nil
        lock.unlock()

        freeBuffers()

        guard let url = outputURL else {
            throw AudioRecorderError.noOutputURL
        }
        outputURL = nil

        // Verify file has content
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? UInt64 ?? 0
        guard size > 44 else {
            logger.warning("Recording file too small (\(size) bytes) — treating as empty")
            throw AudioRecorderError.noOutputURL
        }

        logger.info("Recording stopped — file size: \(size) bytes")
        return url
    }

    // MARK: - AudioUnit Setup

    private func createAudioUnit() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioRecorderError.componentNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw AudioRecorderError.failedToCreateUnit(status)
        }
        self.audioUnit = audioUnit

        // Enable input on element 1
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1,
            &enableInput, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.failedToEnableInput(status)
        }

        // Disable output on element 0 (we only record, no playback)
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0,
            &disableOutput, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.failedToDisableOutput(status)
        }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let unit = audioUnit else {
            throw AudioRecorderError.failedToSetDevice(0)
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.failedToSetDevice(status)
        }
    }

    private func configureFormats() throws {
        guard let unit = audioUnit else { return }

        // Get the device's native format
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 1,
            &deviceFormat, &formatSize
        )
        guard status == noErr else {
            throw AudioRecorderError.failedToSetFormat(status)
        }

        // Set callback format: Float32, device's native rate & channels.
        // Output scope on element 1 = data flowing FROM the device TO our callback.
        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size) * deviceFormat.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size) * deviceFormat.mChannelsPerFrame,
            mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let fmtStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1,
            &callbackFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard fmtStatus == noErr else {
            throw AudioRecorderError.failedToSetFormat(fmtStatus)
        }

        // Pre-allocate render buffer (device's native format)
        let bufferSamples = Self.maxFrames * deviceFormat.mChannelsPerFrame
        renderBuffer = .allocate(capacity: Int(bufferSamples))
        renderBufferSize = bufferSamples

        // Pre-allocate conversion buffer (16kHz mono output)
        let maxOutputFrames = UInt32(Double(Self.maxFrames) * (Self.sampleRate / deviceFormat.mSampleRate)) + 1
        conversionBuffer = .allocate(capacity: Int(maxOutputFrames))
        conversionBufferSize = maxOutputFrames
    }

    private func setupInputCallback() throws {
        guard let unit = audioUnit else { return }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: Self.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.failedToSetCallback(status)
        }
    }

    private func cleanupUnit() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
    }

    private func freeBuffers() {
        renderBuffer?.deallocate()
        renderBuffer = nil
        renderBufferSize = 0
        conversionBuffer?.deallocate()
        conversionBuffer = nil
        conversionBufferSize = 0
        writeBuffer = nil
        targetFormat = nil
    }

    // MARK: - Render Callback (real-time audio thread)

    private static let renderCallback: AURenderCallback = { (
        inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _
    ) -> OSStatus in
        let recorder = Unmanaged<AudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
        return recorder.handleAudioBuffer(
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inBusNumber: inBusNumber,
            inNumberFrames: inNumberFrames
        )
    }

    private func handleAudioBuffer(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let unit = audioUnit, let renderBuf = renderBuffer else { return noErr }

        let channelCount = deviceFormat.mChannelsPerFrame
        let requiredSamples = inNumberFrames * channelCount
        guard requiredSamples <= renderBufferSize else { return noErr }

        // Pull audio data from hardware
        let bytesPerFrame = UInt32(MemoryLayout<Float32>.size) * channelCount
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channelCount,
                mDataByteSize: inNumberFrames * bytesPerFrame,
                mData: renderBuf
            )
        )

        let status = AudioUnitRender(
            unit, ioActionFlags, inTimeStamp,
            inBusNumber, inNumberFrames, &bufferList
        )
        guard status == noErr else { return status }

        // Convert to 16kHz mono Float32
        let inputRate = deviceFormat.mSampleRate
        let outputRate = Self.sampleRate
        let ratio = outputRate / inputRate
        let outputFrameCount = min(
            UInt32(Double(inNumberFrames) * ratio),
            conversionBufferSize
        )
        guard outputFrameCount > 0, let outputBuf = conversionBuffer else { return noErr }

        if inputRate == outputRate {
            // Same sample rate: just mix channels to mono
            for i in 0..<Int(inNumberFrames) {
                var sample: Float32 = 0
                for ch in 0..<Int(channelCount) {
                    sample += renderBuf[i * Int(channelCount) + ch]
                }
                outputBuf[i] = sample / Float32(channelCount)
            }
        } else {
            // Different sample rate: linear interpolation + channel mixing
            for i in 0..<Int(outputFrameCount) {
                let inputIndex = Double(i) / ratio
                let idx = Int(inputIndex)
                let frac = Float32(inputIndex - Double(idx))
                let idx1 = min(idx, Int(inNumberFrames) - 1)
                let idx2 = min(idx + 1, Int(inNumberFrames) - 1)

                var sample: Float32 = 0
                for ch in 0..<Int(channelCount) {
                    let s1 = renderBuf[idx1 * Int(channelCount) + ch]
                    let s2 = renderBuf[idx2 * Int(channelCount) + ch]
                    sample += s1 + frac * (s2 - s1)
                }
                outputBuf[i] = sample / Float32(channelCount)
            }
        }

        // Feed level monitor (lightweight RMS, safe in callback)
        lock.lock()
        let monitor = levelMonitor
        lock.unlock()
        if let monitor {
            let samples = Array(UnsafeBufferPointer(start: outputBuf, count: Int(outputFrameCount)))
            monitor.process(samples: samples)
        }

        // Copy converted data and dispatch file write off the audio thread
        let byteCount = Int(outputFrameCount) * MemoryLayout<Float32>.size
        let writeData = Data(bytes: outputBuf, count: byteCount)
        let frames = outputFrameCount

        writeQueue.async { [weak self] in
            self?.writeToFile(data: writeData, frameCount: frames)
        }

        return noErr
    }

    // MARK: - File Writing (runs on serial writeQueue, off audio thread)

    private func writeToFile(data: Data, frameCount: UInt32) {
        lock.lock()
        let file = audioFile
        lock.unlock()
        guard let file else { return }

        guard let fmt = targetFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBuffer in
            guard let src = rawBuffer.baseAddress?.assumingMemoryBound(to: Float32.self),
                  let dst = buffer.floatChannelData?[0] else { return }
            memcpy(dst, src, Int(frameCount) * MemoryLayout<Float32>.size)
        }

        do {
            try file.write(from: buffer)
        } catch {
            logger.error("Failed to write audio: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case componentNotFound
    case failedToCreateUnit(OSStatus)
    case failedToEnableInput(OSStatus)
    case failedToDisableOutput(OSStatus)
    case failedToSetDevice(OSStatus)
    case failedToSetFormat(OSStatus)
    case failedToSetCallback(OSStatus)
    case failedToInitialize(OSStatus)
    case failedToStart(OSStatus)
    case noOutputURL

    var errorDescription: String? {
        switch self {
        case .componentNotFound: "Audio component not found"
        case .failedToCreateUnit(let s): "Failed to create audio unit: \(s)"
        case .failedToEnableInput(let s): "Failed to enable input: \(s)"
        case .failedToDisableOutput(let s): "Failed to disable output: \(s)"
        case .failedToSetDevice(let s): "Failed to set device: \(s)"
        case .failedToSetFormat(let s): "Failed to set format: \(s)"
        case .failedToSetCallback(let s): "Failed to set callback: \(s)"
        case .failedToInitialize(let s): "Failed to initialize: \(s)"
        case .failedToStart(let s): "Failed to start: \(s)"
        case .noOutputURL: "No output URL"
        }
    }
}
