import Testing
import Foundation
@testable import Speaky

@Suite("TranscriptionCoordinator")
@MainActor
struct TranscriptionCoordinatorTests {

    private func makeCoordinator(
        settings: AppSettings? = nil,
        audioRecorder: MockAudioRecorder = MockAudioRecorder(),
        pasteService: MockPasteService = MockPasteService(),
        audioControl: MockAudioControl = MockAudioControl(),
        modelManager: MockModelManager = MockModelManager(),
        deviceGuard: MockDeviceGuard = MockDeviceGuard(),
        soundEffect: MockSoundEffect = MockSoundEffect(),
        playbackController: MockPlaybackController = MockPlaybackController()
    ) -> (TranscriptionCoordinator, MockAudioRecorder, MockPasteService, MockAudioControl, MockDeviceGuard, MockSoundEffect, MockPlaybackController) {
        let resolvedSettings = settings ?? makeSettings()
        let coordinator = TranscriptionCoordinator(
            settings: resolvedSettings,
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

    private func makeSettings() -> AppSettings {
        AppSettings(store: InMemorySettingsStore())
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
        let settings = makeSettings()
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
        let settings = makeSettings()
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
        let settings = makeSettings()
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
        let settings = makeSettings()
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
        let settings = makeSettings()
        settings.backgroundAudioMode = .pauseMedia
        let (coordinator, _, _, _, _, _, _) = makeCoordinator(
            settings: settings,
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
        let settings = makeSettings()
        settings.backgroundAudioMode = .pauseMedia
        let (coordinator, _, _, _, _, _, _) = makeCoordinator(
            settings: settings,
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

    @Test("playStartSoundAndMute mutes in muteSystemAudio mode")
    func playStartSoundRespectsSettings() async {
        let sound = MockSoundEffect()
        let settings = makeSettings()
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

        await coordinator.playStartSoundAndMute()
        #expect(sound.playStartCalled)
        #expect(control.muteCount == 1)
    }

    @Test("playStartSoundAndMute does not mute in pauseMedia mode")
    func playStartSoundSkipsMuteInPauseMode() async {
        let sound = MockSoundEffect()
        let settings = makeSettings()
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

        await coordinator.playStartSoundAndMute()
        #expect(sound.playStartCalled)
        #expect(control.muteCount == 0)
    }

    @Test("playStartSoundAndMute skips everything when off")
    func playStartSoundSkipsWhenOff() async {
        let sound = MockSoundEffect()
        let settings = makeSettings()
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

        await coordinator.playStartSoundAndMute()
        #expect(!sound.playStartCalled)
        #expect(control.muteCount == 0)
    }
}
