import AppKit
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

    nonisolated deinit {
        // Wake observer and keep-alive task are cleaned up by the runtime
        // since they use [weak self]. No manual cleanup needed in deinit
        // because @MainActor properties cannot be accessed from nonisolated deinit.
    }

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

    /// Full warm-up: resolve the engine and run a dummy inference to prime caches.
    /// Called on app launch, after model switch, and on system wake.
    func warmUpEngine() {
        Task(priority: .userInitiated) {
            do {
                let engine = try await resolveEngine()
                try await engine.warmUp()
                logger.info("Engine preloaded and warmed up successfully")
                startKeepAlive()
            } catch {
                logger.warning("Engine preload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Keep-Alive

    private var keepAliveTask: Task<Void, Never>?
    /// Interval between keep-alive pings (30 minutes).
    private let keepAliveInterval: TimeInterval = 30 * 60

    /// Periodically runs a lightweight inference to keep the engine's internal
    /// caches warm (KV cache, Metal shaders, ANE state). Without this, the
    /// system may reclaim resources after extended idle periods, causing the
    /// next real transcription to pay a cold-start penalty.
    func startKeepAlive() {
        keepAliveTask?.cancel()
        guard settings.autoUnloadTimeout == 0 else { return } // Only when "Never unload"
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.keepAliveInterval ?? 1800))
                guard !Task.isCancelled, let self else { return }
                guard self.currentEngine != nil else { return }
                logger.info("Running keep-alive inference")
                do {
                    let engine = try await self.resolveEngine()
                    try await engine.warmUp()
                    logger.info("Keep-alive completed")
                } catch {
                    logger.warning("Keep-alive failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    // MARK: - System Wake

    private var wakeObserver: NSObjectProtocol?

    /// Observe system wake events and re-warm the engine. Sleep can evict
    /// GPU/ANE state and invalidate compiled Metal shaders, so we need to
    /// re-prime the inference pipeline after waking.
    func observeSystemWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentEngine != nil else { return }
                logger.info("System woke from sleep — re-warming engine")
                // Brief delay to let the system settle after wake
                try? await Task.sleep(for: .seconds(3))
                self.warmUpEngine()
            }
        }
    }

    func removeSystemWakeObserver() {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
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
            guard let apiKey = KeychainHelper.read(service: Constants.keychainService, account: Constants.groqAPIKeyAccount),
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
        stopKeepAlive()
        if let engine = currentEngine {
            await engine.cleanup()
        }
        currentEngine = nil
        currentEngineModelID = nil
    }

    func scheduleEngineUnload() {
        engineUnloadTask?.cancel()
        let timeout = settings.autoUnloadTimeout
        guard timeout > 0 else {
            // "Never unload" — ensure keep-alive is running
            startKeepAlive()
            return
        }
        stopKeepAlive()
        engineUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            logger.info("Auto-unloading engine after \(Int(timeout))s idle")
            await self.unloadCurrentEngine()
        }
    }

    // MARK: - Recording

    private var backgroundLoadTask: Task<Void, Never>?

    func startRecording(onLevelsUpdate: @escaping @Sendable ([Float]) -> Void) throws {
        engineUnloadTask?.cancel()
        engineUnloadTask = nil

        // If the engine isn't loaded, start loading it in the background
        // while recording begins. By the time the user finishes speaking,
        // the model should be ready for transcription.
        if currentEngine == nil {
            logger.info("Engine not loaded — starting background load during recording")
            backgroundLoadTask = Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let engine = try await self.resolveEngine()
                    try await engine.warmUp()
                    logger.info("Background engine load completed during recording")
                } catch {
                    logger.warning("Background engine load failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Pause background media IMMEDIATELY so the user hears silence right away.
        // Only .pauseMedia sends the MediaRemote pause command.
        // .muteSystemAudio only mutes system volume (after start sound) without
        // affecting media playback — videos keep playing visually, just silenced.
        if settings.backgroundAudioMode == .pauseMedia {
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
        // System-level mute — only in muteSystemAudio mode.
        // Mutes system volume so media keeps playing visually but silently.
        if settings.backgroundAudioMode == .muteSystemAudio {
            audioControl.mute()
        }
    }

    func stopRecording() throws -> URL {
        let url = try audioRecorder.stop()
        levelMonitor = nil
        if settings.backgroundAudioMode == .muteSystemAudio {
            audioControl.unmute()
        }
        if settings.backgroundAudioMode == .pauseMedia {
            playbackController.resume()
        }
        deviceGuard.unlock()
        logger.info("Recording stopped — beginning transcription")
        return url
    }

    func cancelRecording() {
        backgroundLoadTask?.cancel()
        backgroundLoadTask = nil
        do {
            let audioURL = try audioRecorder.stop()
            try? FileManager.default.removeItem(at: audioURL)
        } catch {
            logger.debug("cancelRecording cleanup: \(error.localizedDescription, privacy: .public)")
        }
        levelMonitor = nil
        if settings.backgroundAudioMode == .muteSystemAudio {
            audioControl.unmute()
        }
        if settings.backgroundAudioMode == .pauseMedia {
            playbackController.resume()
        }
        deviceGuard.unlock()
    }

    // MARK: - Transcription

    /// Result of the full transcription pipeline including paste outcome.
    struct TranscriptionPipelineResult {
        let text: String
        let pasteResult: PasteResult?
    }

    /// Run the full transcription pipeline: transcribe with resilience,
    /// apply cleanup, paste, and play sound effects.
    /// Returns the final text and paste result on success, or throws on failure.
    func transcribe(audioFileURL: URL, recordingDuration: TimeInterval) async throws -> TranscriptionPipelineResult {
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

        var pasteResult: PasteResult?
        if settings.autoPaste {
            pasteResult = pasteService.paste(finalText)
        }
        if settings.soundEffectsEnabled {
            soundEffect.playEnd()
        }

        return TranscriptionPipelineResult(text: finalText, pasteResult: pasteResult)
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
            guard let result = try await group.next() else {
                throw TranscriptionError.engineError("Transcription produced no result")
            }
            group.cancelAll()
            return result
        }
    }
}
