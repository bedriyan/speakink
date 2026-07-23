import Testing
import Foundation
@testable import Speaky

@Suite("TranscriptionCoordinator", .serialized)
@MainActor
struct TranscriptionCoordinatorTests {
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func makeCoordinator(
        audioRecorder: MockAudioRecorder = MockAudioRecorder(),
        pasteService: MockPasteService = MockPasteService(),
        audioControl: MockAudioControl = MockAudioControl(),
        modelManager: MockModelManager = MockModelManager(),
        deviceGuard: MockDeviceGuard = MockDeviceGuard(),
        soundEffect: MockSoundEffect = MockSoundEffect(),
        playbackController: MockPlaybackController = MockPlaybackController()
    ) -> (TranscriptionCoordinator, MockAudioRecorder, MockPasteService, MockAudioControl, MockDeviceGuard, MockSoundEffect, MockPlaybackController) {
        let settings = AppSettings()
        let coordinator = TranscriptionCoordinator(
            settings: settings,
            audioRecorder: audioRecorder,
            pasteService: pasteService,
            audioControl: audioControl,
            modelManager: modelManager,
            deviceGuard: deviceGuard,
            soundEffect: soundEffect,
            playbackController: playbackController
        )
        return (coordinator, audioRecorder, pasteService, audioControl, deviceGuard, soundEffect, playbackController)
    }

    @Test("startRecording calls audio recorder")
    func startRecordingCallsRecorder() throws {
        let recorder = MockAudioRecorder()
        let (coordinator, _, _, _, _, _, _) = makeCoordinator(audioRecorder: recorder)
        try coordinator.startRecording { _ in }
        #expect(recorder.startCalled)
    }

    @Test("startRecording locks device guard when device is selected")
    func startRecordingLocksDevice() throws {
        let guard_ = MockDeviceGuard()
        let settings = AppSettings()
        settings.selectedAudioDevice = 42
        let coordinator = TranscriptionCoordinator(
            settings: settings,
            audioRecorder: MockAudioRecorder(),
            pasteService: MockPasteService(),
            audioControl: MockAudioControl(),
            modelManager: MockModelManager(),
            deviceGuard: guard_,
            soundEffect: MockSoundEffect(),
            playbackController: MockPlaybackController()
        )
        try coordinator.startRecording { _ in }
        #expect(guard_.lockedDeviceID == 42)
    }

    @Test("startRecording pauses playback when pauseMedia mode")
    func startRecordingPausesPlayback() throws {
        let playback = MockPlaybackController()
        let settings = AppSettings()
        settings.backgroundAudioMode = .pauseMedia
        let coordinator = TranscriptionCoordinator(
            settings: settings,
            audioRecorder: MockAudioRecorder(),
            pasteService: MockPasteService(),
            audioControl: MockAudioControl(),
            modelManager: MockModelManager(),
            deviceGuard: MockDeviceGuard(),
            soundEffect: MockSoundEffect(),
            playbackController: playback
        )
        try coordinator.startRecording { _ in }
        #expect(playback.pauseCount == 1)
    }

    @Test("startRecording does not pause media in muteSystemAudio mode")
    func startRecordingMutesSystemAudio() throws {
        let playback = MockPlaybackController()
        let settings = AppSettings()
        settings.backgroundAudioMode = .muteSystemAudio
        let coordinator = TranscriptionCoordinator(
            settings: settings,
            audioRecorder: MockAudioRecorder(),
            pasteService: MockPasteService(),
            audioControl: MockAudioControl(),
            modelManager: MockModelManager(),
            deviceGuard: MockDeviceGuard(),
            soundEffect: MockSoundEffect(),
            playbackController: playback
        )
        try coordinator.startRecording { _ in }
        #expect(playback.pauseCount == 0)
    }

    @Test("startRecording skips pause when background audio mode is off")
    func startRecordingSkipsPauseWhenOff() throws {
        let playback = MockPlaybackController()
        let settings = AppSettings()
        settings.backgroundAudioMode = .off
        let coordinator = TranscriptionCoordinator(
            settings: settings,
            audioRecorder: MockAudioRecorder(),
            pasteService: MockPasteService(),
            audioControl: MockAudioControl(),
            modelManager: MockModelManager(),
            deviceGuard: MockDeviceGuard(),
            soundEffect: MockSoundEffect(),
            playbackController: playback
        )
        try coordinator.startRecording { _ in }
        #expect(playback.pauseCount == 0)
    }

    @Test("stopRecording resumes playback and unlocks device in pauseMedia mode")
    func stopRecordingUnmutesAndUnlocks() throws {
        let recorder = MockAudioRecorder()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.wav")
        FileManager.default.createFile(atPath: tempURL.path, contents: Data(count: 100))
        recorder.stopURL = tempURL
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let control = MockAudioControl()
        let guard_ = MockDeviceGuard()
        let playback = MockPlaybackController()
        let (coordinator, _, _, _, _, _, _) = makeCoordinator(
            audioRecorder: recorder,
            audioControl: control,
            deviceGuard: guard_,
            playbackController: playback
        )

        _ = try coordinator.stopRecording()
        #expect(control.unmuteCount == 0)
        #expect(guard_.unlockCalled)
        #expect(playback.resumeCount == 1)
    }

    @Test("cancelRecording cleans up resources and resumes playback")
    func cancelRecordingCleansUp() throws {
        let recorder = MockAudioRecorder()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("cancel_test.wav")
        FileManager.default.createFile(atPath: tempURL.path, contents: Data(count: 100))
        recorder.stopURL = tempURL
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let control = MockAudioControl()
        let guard_ = MockDeviceGuard()
        let playback = MockPlaybackController()
        let (coordinator, _, _, _, _, _, _) = makeCoordinator(
            audioRecorder: recorder,
            audioControl: control,
            deviceGuard: guard_,
            playbackController: playback
        )

        coordinator.cancelRecording()
        #expect(recorder.stopCalled)
        #expect(control.unmuteCount == 0)
        #expect(guard_.unlockCalled)
        #expect(playback.resumeCount == 1)
    }

    @Test("recording feedback mutes in muteSystemAudio mode")
    func playStartSoundRespectsSettings() async {
        let sound = MockSoundEffect()
        let settings = AppSettings()
        settings.soundEffectsEnabled = true
        settings.backgroundAudioMode = .muteSystemAudio

        let control = MockAudioControl()
        let coordinator = TranscriptionCoordinator(
            settings: settings,
            audioRecorder: MockAudioRecorder(),
            pasteService: MockPasteService(),
            audioControl: control,
            modelManager: MockModelManager(),
            deviceGuard: MockDeviceGuard(),
            soundEffect: sound,
            playbackController: MockPlaybackController()
        )

        coordinator.startRecordingFeedback { true }
        let feedbackCompleted = await waitUntil {
            sound.playStartCallCount == 1 && control.muteCount == 1
        }
        #expect(feedbackCompleted)
        #expect(sound.playStartCalled)
        #expect(control.muteCount == 1)
    }

    @Test("recording feedback does not mute in pauseMedia mode")
    func playStartSoundSkipsMuteInPauseMode() async {
        let sound = MockSoundEffect()
        let settings = AppSettings()
        settings.soundEffectsEnabled = true
        settings.backgroundAudioMode = .pauseMedia

        let control = MockAudioControl()
        let coordinator = TranscriptionCoordinator(
            settings: settings,
            audioRecorder: MockAudioRecorder(),
            pasteService: MockPasteService(),
            audioControl: control,
            modelManager: MockModelManager(),
            deviceGuard: MockDeviceGuard(),
            soundEffect: sound,
            playbackController: MockPlaybackController()
        )

        coordinator.startRecordingFeedback { true }
        #expect(await waitUntil { sound.playStartCallCount == 1 })
        #expect(sound.playStartCalled)
        #expect(control.muteCount == 0)
    }

    @Test("recording feedback skips everything when off")
    func playStartSoundSkipsWhenOff() async {
        let sound = MockSoundEffect()
        let settings = AppSettings()
        settings.soundEffectsEnabled = false
        settings.backgroundAudioMode = .off

        let control = MockAudioControl()
        let coordinator = TranscriptionCoordinator(
            settings: settings,
            audioRecorder: MockAudioRecorder(),
            pasteService: MockPasteService(),
            audioControl: control,
            modelManager: MockModelManager(),
            deviceGuard: MockDeviceGuard(),
            soundEffect: sound,
            playbackController: MockPlaybackController()
        )

        coordinator.startRecordingFeedback { true }
        await Task.yield()
        #expect(!sound.playStartCalled)
        #expect(control.muteCount == 0)
    }

    @Test("cancelled start feedback cannot mute a restarted recording")
    func cancelledFeedbackCannotMuteRestart() async {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: "backgroundAudioMode")
        let previousSoundSetting = defaults.object(forKey: "soundEffectsEnabled")
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: "backgroundAudioMode")
            } else {
                defaults.removeObject(forKey: "backgroundAudioMode")
            }
            if let previousSoundSetting {
                defaults.set(previousSoundSetting, forKey: "soundEffectsEnabled")
            } else {
                defaults.removeObject(forKey: "soundEffectsEnabled")
            }
        }

        let settings = AppSettings()
        settings.backgroundAudioMode = .muteSystemAudio
        settings.soundEffectsEnabled = true
        let sound = MockSoundEffect()
        sound.waitsForStartCompletion = true
        let control = MockAudioControl()
        let coordinator = TranscriptionCoordinator(
            settings: settings,
            audioRecorder: MockAudioRecorder(),
            pasteService: MockPasteService(),
            audioControl: control,
            modelManager: MockModelManager(),
            deviceGuard: MockDeviceGuard(),
            soundEffect: sound,
            playbackController: MockPlaybackController()
        )

        coordinator.startRecordingFeedback { true }
        #expect(await waitUntil { sound.playStartCallCount == 1 })

        coordinator.cancelRecordingFeedback()
        coordinator.startRecordingFeedback { true }
        #expect(await waitUntil { sound.playStartCallCount == 2 })

        #expect(control.muteCount == 0)

        sound.finishStartSound()
        #expect(await waitUntil { control.muteCount == 1 })

        #expect(control.muteCount == 1)
        #expect(sound.stopStartCallCount == 1)
        coordinator.cancelRecordingFeedback()
    }
}
