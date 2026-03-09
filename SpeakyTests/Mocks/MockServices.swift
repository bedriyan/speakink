import Foundation
import CoreAudio
@testable import Speaky

// MARK: - Mock Audio Recorder

final class MockAudioRecorder: AudioRecording, @unchecked Sendable {
    var startCalled = false
    var stopCalled = false
    var startError: Error?
    var stopURL: URL?

    func start(deviceID: UInt32?, levelMonitor: AudioLevelMonitor?) throws {
        if let error = startError { throw error }
        startCalled = true
    }

    func stop() throws -> URL {
        stopCalled = true
        guard let url = stopURL else {
            throw AudioRecorderError.noOutputURL
        }
        return url
    }
}

// MARK: - Mock Paste Service

final class MockPasteService: Pasting, @unchecked Sendable {
    var pastedTexts: [String] = []

    func paste(_ text: String) {
        pastedTexts.append(text)
    }
}

// MARK: - Mock Audio Control

final class MockAudioControl: AudioControlling, @unchecked Sendable {
    var muteCount = 0
    var unmuteCount = 0

    func mute() { muteCount += 1 }
    func unmute() { unmuteCount += 1 }
}

// MARK: - Mock Device Guard

final class MockDeviceGuard: DeviceGuarding, @unchecked Sendable {
    var onDeviceLost: (() -> Void)?
    var lockedDeviceID: AudioDeviceID?
    var unlockCalled = false

    func lock(to deviceID: AudioDeviceID) {
        lockedDeviceID = deviceID
    }

    func unlock() {
        lockedDeviceID = nil
        unlockCalled = true
    }
}

// MARK: - Mock Sound Effect

@MainActor
final class MockSoundEffect: SoundEffecting {
    var playStartCalled = false
    var playEndCalled = false

    func playStartAndWait() async {
        playStartCalled = true
    }

    func playEnd() {
        playEndCalled = true
    }
}

// MARK: - Mock Model Manager

final class MockModelManager: ModelManaging, @unchecked Sendable {
    var downloadProgress: [String: Double] = [:]
    var downloadedModels: Set<String> = []
    var ensureModelResult: String = "/mock/model/path"

    func isDownloaded(_ model: TranscriptionModelInfo) -> Bool {
        downloadedModels.contains(model.id)
    }

    func ensureModel(_ model: TranscriptionModelInfo) async throws -> String {
        ensureModelResult
    }

    func deleteModel(_ model: TranscriptionModelInfo) throws {
        downloadedModels.remove(model.id)
    }

    func importCustomModel(from sourceURL: URL) throws -> String {
        "/mock/custom/path"
    }

    @discardableResult
    func downloadModel(id: String, from url: URL, fileName: String) async throws -> String {
        downloadedModels.insert(id)
        return "/mock/\(fileName)"
    }

    @MainActor
    func downloadParakeetModel(_ model: TranscriptionModelInfo) async throws {
        downloadedModels.insert(model.id)
    }

    func deleteParakeetModel(_ model: TranscriptionModelInfo) {
        downloadedModels.remove(model.id)
    }
}

// MARK: - Mock Playback Controller

final class MockPlaybackController: PlaybackControlling, @unchecked Sendable {
    var pauseCount = 0
    var resumeCount = 0

    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
}
