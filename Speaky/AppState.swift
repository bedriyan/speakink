import Foundation
import SwiftUI
import SwiftData
import DynamicNotchKit
import AppKit
import os

enum RecordingState: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)
}

private let appStateLogger = Logger.speaky(category: "AppState")

@Observable
@MainActor
final class AppState {
    var state: RecordingState = .idle
    var lastTranscription: String?
    var audioLevels: [Float] = Array(repeating: 0, count: 30)
    var recordingStartTime: Date?
    var showingCancelWarning = false
    var showingCelebration = false
    private var cancelWarningDismissTask: Task<Void, Never>?

    let settings = AppSettings()
    let audioRecorder = AudioRecorder()
    let pasteService = PasteService()
    let audioControl = AudioControlService()
    let modelManager = ModelManager()
    let hotkeyManager = HotkeyManager()
    let deviceGuard = DeviceGuard()
    let soundEffect = SoundEffectService()
    private(set) var currentEngine: (any TranscriptionEngine)?

    // SwiftData container for saving transcriptions
    var modelContext: ModelContext?

    private var levelMonitor: AudioLevelMonitor?
    private var notch: DynamicNotch<NotchRecordingView, EmptyView, EmptyView>?
    private var engineUnloadTask: Task<Void, Never>?

    init() {
        hotkeyManager.onToggleRecording = { [weak self] in
            self?.toggleRecording()
        }
        hotkeyManager.onEscapePressed = { [weak self] in
            self?.handleEscapePressed()
        }
        deviceGuard.onDeviceLost = { [weak self] in
            guard let self else { return }
            if self.isRecording {
                appStateLogger.warning("Audio device disconnected during recording — cancelling")
                self.cancelRecording()
                self.state = .error("Audio device disconnected")
            }
        }
    }

    /// Pre-warm the selected engine so first transcription is fast.
    /// Resolves the engine AND loads models into memory (CoreML compile, etc).
    func warmUpEngine() {
        Task(priority: .userInitiated) {
            do {
                let engine = try await resolveEngine()
                try await engine.warmUp()
                appStateLogger.info("Engine preloaded and warmed up successfully")
            } catch {
                appStateLogger.warning("Engine preload failed: \(error.localizedDescription, privacy: .public)")
                // Non-fatal: engine will load on first transcription
            }
        }
    }

    var menuBarIconName: String {
        switch state {
        case .idle: "mic.fill"
        case .recording: "mic.badge.waveform.fill"
        case .transcribing: "ellipsis.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var isRecording: Bool { state == .recording }
    var isTranscribing: Bool { state == .transcribing }

    private var transcriptionTask: Task<Void, Never>?

    func toggleRecording() {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        case .transcribing:
            // Allow cancelling a stuck transcription
            cancelTranscription()
        }
    }

    private func startRecording() {
        do {
            engineUnloadTask?.cancel()
            engineUnloadTask = nil
            state = .recording
            recordingStartTime = Date()
            showingCancelWarning = false
            showingCelebration = false
            audioLevels = Array(repeating: 0, count: 30)
            levelMonitor = AudioLevelMonitor { [weak self] levels in
                Task { @MainActor in
                    self?.audioLevels = levels
                }
            }
            try audioRecorder.start(deviceID: settings.selectedAudioDevice, levelMonitor: levelMonitor)
            let deviceDesc = settings.selectedAudioDevice.map(String.init) ?? "default"
            appStateLogger.info("Recording started — device: \(deviceDesc, privacy: .public)")

            // Lock to selected device so Bluetooth changes don't hijack recording
            if let deviceID = settings.selectedAudioDevice {
                deviceGuard.lock(to: deviceID)
            }

            showNotch()

            // Play start sound (if enabled), then mute system audio after it finishes
            Task {
                if settings.soundEffectsEnabled {
                    await soundEffect.playStartAndWait()
                }
                if settings.muteSystemAudio {
                    audioControl.mute()
                }
            }

        } catch {
            appStateLogger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
            state = .error("Failed to start recording: \(error.localizedDescription)")
            audioControl.unmute()
        }
    }

    private func stopRecordingAndTranscribe() {
        let recordStart = recordingStartTime ?? Date()
        let audioURL: URL
        do {
            audioURL = try audioRecorder.stop()
            appStateLogger.info("Recording stopped — beginning transcription")
        } catch {
            appStateLogger.error("Failed to stop recording: \(error.localizedDescription, privacy: .public)")
            state = .error("Failed to stop recording: \(error.localizedDescription)")
            audioControl.unmute()
            hideNotch()
            return
        }

        levelMonitor = nil
        audioControl.unmute()
        deviceGuard.unlock()
        state = .transcribing
        audioLevels = Array(repeating: 0, count: 30)

        let recordingDuration = Date().timeIntervalSince(recordStart)
        let selectedModelID = settings.selectedModel.id
        let selectedLanguage = settings.language

        transcriptionTask = Task {
            defer {
                // Clean up temp audio file AFTER all retry attempts complete
                hideNotch()
                recordingStartTime = nil
                transcriptionTask = nil
                try? FileManager.default.removeItem(at: audioURL)
            }

            guard !Task.isCancelled else { return }

            // Persist audio file
            let savedAudioURL = Constants.recordingsPath
                .appendingPathComponent("recording_\(UUID().uuidString).wav")
            var savedAudioPath: String? = nil
            do {
                try FileManager.default.copyItem(at: audioURL, to: savedAudioURL)
                savedAudioPath = savedAudioURL.path
            } catch {
                appStateLogger.warning("Failed to persist audio file: \(error.localizedDescription, privacy: .public)")
                // Non-fatal: continue without persisted audio
            }

            do {
                let engine = try await resolveEngine()
                let result = try await transcribeWithResilience(
                    engine: engine,
                    audioFileURL: audioURL,
                    language: selectedLanguage
                )

                var finalText = result.text

                // Apply text cleanup if enabled
                if settings.cleanUpTranscriptions {
                    finalText = TextCleanupService.clean(finalText)
                }

                lastTranscription = finalText

                // Save to SwiftData
                saveTranscription(
                    text: finalText,
                    duration: recordingDuration,
                    modelID: selectedModelID,
                    language: selectedLanguage,
                    audioFileURL: savedAudioPath
                )

                appStateLogger.info("Transcription complete — \(finalText.count) characters")
                if settings.autoPaste {
                    pasteService.paste(finalText)
                }
                if settings.soundEffectsEnabled {
                    soundEffect.playEnd()
                }
                state = .idle
                showingCelebration = true
                scheduleEngineUnload()
            } catch {
                let errorMsg = error.localizedDescription
                appStateLogger.error("Transcription failed: \(errorMsg, privacy: .public)")
                state = .error("Transcription failed: \(errorMsg)")
                scheduleEngineUnload()

                // Save failed attempt too
                saveTranscription(
                    text: "[Transcription failed: \(errorMsg)]",
                    duration: recordingDuration,
                    modelID: selectedModelID,
                    language: selectedLanguage,
                    audioFileURL: savedAudioPath
                )
            }
        }
    }

    private func saveTranscription(text: String, duration: TimeInterval, modelID: String, language: String, audioFileURL: String? = nil) {
        guard let modelContext else { return }
        let transcription = Transcription(
            text: text,
            duration: duration,
            modelID: modelID,
            language: language,
            audioFileURL: audioFileURL
        )
        modelContext.insert(transcription)
        do {
            try modelContext.save()
        } catch {
            appStateLogger.warning("Failed to save transcription: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Notch Overlay

    private func showNotch() {
        let notch = DynamicNotch(style: .auto) { [weak self] in
            NotchRecordingView(appState: self)
        }
        self.notch = notch
        Task {
            await notch.expand()
            // Force dark appearance on the overlay window so it renders dark
            // on all displays regardless of system appearance setting
            notch.windowController?.window?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func hideNotch() {
        if let notch {
            Task {
                await notch.hide()
            }
            self.notch = nil
        }
    }

    func handleEscapePressed() {
        guard isRecording else { return }

        if showingCancelWarning {
            // Second ESC → cancel recording
            cancelRecording()
        } else {
            // First ESC → show warning
            showingCancelWarning = true
            cancelWarningDismissTask?.cancel()
            cancelWarningDismissTask = Task {
                try? await Task.sleep(for: .seconds(Constants.Timing.cancelWarningDuration))
                guard !Task.isCancelled else { return }
                self.showingCancelWarning = false
            }
        }
    }

    func cancelRecording() {
        showingCancelWarning = false
        cancelWarningDismissTask?.cancel()

        // Stop recording without transcribing
        do {
            let audioURL = try audioRecorder.stop()
            try? FileManager.default.removeItem(at: audioURL)
        } catch {
            // Ignore — just cleaning up
        }

        levelMonitor = nil
        audioControl.unmute()
        deviceGuard.unlock()
        state = .idle
        audioLevels = Array(repeating: 0, count: 30)
        recordingStartTime = nil
        hideNotch()
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        state = .idle
        hideNotch()
        appStateLogger.info("Transcription cancelled by user")
    }

    private var currentEngineModelID: String?

    func resolveEngine(model: TranscriptionModelInfo? = nil) async throws -> any TranscriptionEngine {
        let model = model ?? settings.selectedModel

        // Reuse current engine if model hasn't changed
        if let engine = currentEngine, currentEngineModelID == model.id {
            return engine
        }

        // Clean up previous engine
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

    /// Schedule engine auto-unload after the configured idle timeout.
    /// Resets any existing timer so each transcription extends the window.
    private func scheduleEngineUnload() {
        engineUnloadTask?.cancel()
        let timeout = settings.autoUnloadTimeout
        guard timeout > 0 else { return }
        engineUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            appStateLogger.info("Auto-unloading engine after \(Int(timeout))s idle")
            await self.unloadCurrentEngine()
        }
    }

    // MARK: - Resilient Transcription

    /// Wraps a transcription call with a 120-second timeout and one automatic retry
    /// with engine reload on failure.
    private func transcribeWithResilience(
        engine: any TranscriptionEngine,
        audioFileURL: URL,
        language: String
    ) async throws -> TranscriptionResult {
        do {
            return try await performTimedTranscription(engine: engine, audioFileURL: audioFileURL, language: language)
        } catch {
            appStateLogger.warning("Transcription attempt 1 failed: \(error.localizedDescription, privacy: .public). Retrying with fresh engine...")
            await unloadCurrentEngine()
            let freshEngine = try await resolveEngine()
            return try await performTimedTranscription(engine: freshEngine, audioFileURL: audioFileURL, language: language)
        }
    }

    /// Run a single transcription with a timeout guard.
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
