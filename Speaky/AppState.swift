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
    let hotkeyManager = HotkeyManager()
    let modelManager = ModelManager()
    let updateService = UpdateService()
    private(set) lazy var coordinator: TranscriptionCoordinator = TranscriptionCoordinator(
        settings: settings,
        modelManager: modelManager
    )

    // SwiftData container for saving transcriptions
    var modelContext: ModelContext?

    private var notch: DynamicNotch<NotchRecordingView, EmptyView, EmptyView>?
    private var transcriptionTask: Task<Void, Never>?

    init() {
        hotkeyManager.onToggleRecording = { [weak self] in
            self?.toggleRecording()
        }
        hotkeyManager.onEscapePressed = { [weak self] in
            self?.handleEscapePressed()
        }
        coordinator.deviceGuard.onDeviceLost = { [weak self] in
            guard let self else { return }
            if self.isRecording {
                appStateLogger.warning("Audio device disconnected during recording — cancelling")
                self.cancelRecording()
                self.state = .error("Audio device disconnected")
            }
        }
    }

    /// Pre-warm the selected engine so first transcription is fast.
    func warmUpEngine() {
        coordinator.warmUpEngine()
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

    // MARK: - Recording

    private func startRecording() {
        do {
            try coordinator.startRecording { [weak self] levels in
                Task { @MainActor in
                    self?.audioLevels = levels
                }
            }

            state = .recording
            recordingStartTime = Date()
            showingCancelWarning = false
            showingCelebration = false
            audioLevels = Array(repeating: 0, count: 30)

            showNotch()

            // Play start sound (if enabled), then apply system-level mute after it finishes.
            // Media is already paused above, so background audio is silent during the sound.
            Task {
                await coordinator.playStartSoundAndMute()
            }

        } catch {
            appStateLogger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
            state = .error("Failed to start recording: \(error.localizedDescription)")
            coordinator.playbackController.resume()
            coordinator.audioControl.unmute()
        }
    }

    private func stopRecordingAndTranscribe() {
        let recordStart = recordingStartTime ?? Date()
        let audioURL: URL
        do {
            audioURL = try coordinator.stopRecording()
        } catch {
            appStateLogger.error("Failed to stop recording: \(error.localizedDescription, privacy: .public)")
            state = .error("Failed to stop recording: \(error.localizedDescription)")
            coordinator.audioControl.unmute()
            coordinator.playbackController.resume()
            hideNotch()
            return
        }

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
                let finalText = try await coordinator.transcribe(
                    audioFileURL: audioURL,
                    recordingDuration: recordingDuration
                )

                lastTranscription = finalText

                // Save to SwiftData
                saveTranscription(
                    text: finalText,
                    duration: recordingDuration,
                    modelID: selectedModelID,
                    language: selectedLanguage,
                    audioFileURL: savedAudioPath
                )

                state = .idle
                showingCelebration = true
                coordinator.scheduleEngineUnload()
            } catch {
                let errorMsg = error.localizedDescription
                appStateLogger.error("Transcription failed: \(errorMsg, privacy: .public)")
                state = .error("Transcription failed: \(errorMsg)")
                coordinator.scheduleEngineUnload()

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

    // MARK: - Persistence

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

    // MARK: - Cancel Handling

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
        coordinator.cancelRecording()
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

    // MARK: - Retranscribe

    func retranscribe(_ transcription: Transcription) async throws {
        guard let audioPath = transcription.audioFileURL else {
            throw TranscriptionError.engineError("Audio file not available")
        }
        let audioURL = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw TranscriptionError.engineError("Audio file no longer exists")
        }

        let finalText = try await coordinator.retranscribe(audioFileURL: audioURL)

        transcription.text = finalText
        transcription.modelID = settings.selectedModel.id
        transcription.language = settings.language
        transcription.date = Date()

        if let modelContext {
            try modelContext.save()
        }
    }
}
