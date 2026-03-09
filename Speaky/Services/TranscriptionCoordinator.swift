import Foundation
import os

private let logger = Logger.speaky(category: "TranscriptionCoordinator")

/// Orchestrates the record → transcribe → paste pipeline.
///
/// Owns engine lifecycle, audio recording, transcription with resilience,
/// and post-transcription actions (cleanup, paste, sound effects).
/// UI state management remains in AppState.
@MainActor
final class TranscriptionCoordinator {
    let audioRecorder: any AudioRecording
    let pasteService: any Pasting
    let audioControl: any AudioControlling
    let modelManager: any ModelManaging
    let deviceGuard: any DeviceGuarding
    let soundEffect: any SoundEffecting
    let playbackController: any PlaybackControlling

    private(set) var currentEngine: (any TranscriptionEngine)?
    private var currentEngineModelID: String?
    private var engineUnloadTask: Task<Void, Never>?
    private var levelMonitor: AudioLevelMonitor?

    private let settings: AppSettings

    init(
        settings: AppSettings,
        audioRecorder: any AudioRecording = AudioRecorder(),
        pasteService: any Pasting = PasteService(),
        audioControl: any AudioControlling = AudioControlService(),
        modelManager: any ModelManaging = ModelManager(),
        deviceGuard: any DeviceGuarding = DeviceGuard(),
        soundEffect: any SoundEffecting = SoundEffectService(),
        playbackController: any PlaybackControlling = PlaybackController()
    ) {
        self.settings = settings
        self.audioRecorder = audioRecorder
        self.pasteService = pasteService
        self.audioControl = audioControl
        self.modelManager = modelManager
        self.deviceGuard = deviceGuard
        self.soundEffect = soundEffect
        self.playbackController = playbackController
    }

    // MARK: - Engine Management

    func warmUpEngine() {
        Task(priority: .userInitiated) {
            do {
                let engine = try await resolveEngine()
                try await engine.warmUp()
                logger.info("Engine preloaded and warmed up successfully")
            } catch {
                logger.warning("Engine preload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func resolveEngine(model: TranscriptionModelInfo? = nil) async throws -> any TranscriptionEngine {
        let model = model ?? settings.selectedModel

        if let engine = currentEngine, currentEngineModelID == model.id {
            return engine
        }

        if let engine = currentEngine {
            await engine.cleanup()
        }

        let engine: any TranscriptionEngine

        switch model.type {
        case .whisper:
            let modelPath = try await modelManager.ensureModel(model)
            let whisper = WhisperEngine()
            try await whisper.loadModel(path: modelPath)
            engine = whisper
        case .parakeet:
            guard modelManager.isDownloaded(model) else {
                throw TranscriptionError.modelNotLoaded
            }
            engine = ParakeetEngine()
        case .groq:
            guard let apiKey = KeychainHelper.read(service: Constants.keychainService, account: "groq-api-key"),
                  !apiKey.isEmpty else {
                throw TranscriptionError.engineError("Groq API key not configured. Add it in Settings.")
            }
            engine = GroqEngine(apiKey: apiKey)
        }

        currentEngine = engine
        currentEngineModelID = model.id
        return engine
    }

    func unloadCurrentEngine() async {
        engineUnloadTask?.cancel()
        engineUnloadTask = nil
        if let engine = currentEngine {
            await engine.cleanup()
        }
        currentEngine = nil
        currentEngineModelID = nil
    }

    func scheduleEngineUnload() {
        engineUnloadTask?.cancel()
        let timeout = settings.autoUnloadTimeout
        guard timeout > 0 else { return }
        engineUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            logger.info("Auto-unloading engine after \(Int(timeout))s idle")
            await self.unloadCurrentEngine()
        }
    }

    // MARK: - Recording

    func startRecording(onLevelsUpdate: @escaping @Sendable ([Float]) -> Void) throws {
        engineUnloadTask?.cancel()
        engineUnloadTask = nil

        // Pause background media IMMEDIATELY so the user hears silence right away.
        if settings.muteSystemAudio {
            playbackController.pause()
        }

        levelMonitor = AudioLevelMonitor(onLevels: onLevelsUpdate)

        // Resolve device ID: when "Auto" (nil), prefer built-in mic to avoid
        // Bluetooth hijacking the input device when headphones connect.
        let deviceID: UInt32?
        if let selected = settings.selectedAudioDevice {
            deviceID = selected
        } else {
            deviceID = AudioControlService.builtInInputDevice()?.id
        }

        try audioRecorder.start(deviceID: deviceID, levelMonitor: levelMonitor)
        let deviceDesc = deviceID.map(String.init) ?? "system-default"
        logger.info("Recording started — device: \(deviceDesc, privacy: .public)")

        // Lock to resolved device so Bluetooth changes don't hijack recording
        if let deviceID {
            deviceGuard.lock(to: deviceID)
        }
    }

    func playStartSoundAndMute() async {
        if settings.soundEffectsEnabled {
            await soundEffect.playStartAndWait()
        }
        if settings.muteSystemAudio {
            audioControl.mute()
        }
    }

    func stopRecording() throws -> URL {
        let url = try audioRecorder.stop()
        levelMonitor = nil
        audioControl.unmute()
        playbackController.resume()
        deviceGuard.unlock()
        logger.info("Recording stopped — beginning transcription")
        return url
    }

    func cancelRecording() {
        do {
            let audioURL = try audioRecorder.stop()
            try? FileManager.default.removeItem(at: audioURL)
        } catch {
            // Ignore — just cleaning up
        }
        levelMonitor = nil
        audioControl.unmute()
        playbackController.resume()
        deviceGuard.unlock()
    }

    // MARK: - Transcription

    /// Run the full transcription pipeline: transcribe with resilience,
    /// apply cleanup, paste, and play sound effects.
    /// Returns the final text on success, or throws on failure.
    func transcribe(audioFileURL: URL, recordingDuration: TimeInterval) async throws -> String {
        let engine = try await resolveEngine()
        let result = try await transcribeWithResilience(
            engine: engine,
            audioFileURL: audioFileURL,
            language: settings.language
        )

        var finalText = result.text
        if settings.cleanUpTranscriptions {
            finalText = TextCleanupService.clean(finalText)
        }

        logger.info("Transcription complete — \(finalText.count) characters")

        if settings.autoPaste {
            pasteService.paste(finalText)
        }
        if settings.soundEffectsEnabled {
            soundEffect.playEnd()
        }

        return finalText
    }

    // MARK: - Retranscribe

    func retranscribe(audioFileURL: URL) async throws -> String {
        let engine = try await resolveEngine()
        let result = try await engine.transcribe(audioFileURL: audioFileURL, language: settings.language)

        var finalText = result.text
        if settings.cleanUpTranscriptions {
            finalText = TextCleanupService.clean(finalText)
        }

        return finalText
    }

    // MARK: - Resilient Transcription

    private func transcribeWithResilience(
        engine: any TranscriptionEngine,
        audioFileURL: URL,
        language: String
    ) async throws -> TranscriptionResult {
        do {
            return try await performTimedTranscription(engine: engine, audioFileURL: audioFileURL, language: language)
        } catch {
            logger.warning("Transcription attempt 1 failed: \(error.localizedDescription, privacy: .public). Retrying with fresh engine...")
            await unloadCurrentEngine()
            let freshEngine = try await resolveEngine()
            return try await performTimedTranscription(engine: freshEngine, audioFileURL: audioFileURL, language: language)
        }
    }

    private func performTimedTranscription(
        engine: any TranscriptionEngine,
        audioFileURL: URL,
        language: String
    ) async throws -> TranscriptionResult {
        try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
            group.addTask {
                try await engine.transcribe(audioFileURL: audioFileURL, language: language)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Constants.Timing.transcriptionTimeout))
                throw TranscriptionError.engineError("Transcription timed out after \(Int(Constants.Timing.transcriptionTimeout)) seconds")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
