import Foundation
import SwiftUI
import SwiftData
import DynamicNotchKit
import AppKit
import AVFoundation
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
    var permissionWarning: String?
    var pasteWarning: String?
    private var cancelWarningDismissTask: Task<Void, Never>?
    private var pasteWarningDismissTask: Task<Void, Never>?

    let settings = AppSettings()
    let hotkeyManager = HotkeyManager()
    let modelManager = ModelManager()
    let updaterManager = UpdaterManager()
    private(set) var coordinator: TranscriptionCoordinator!

    // SwiftData container for saving transcriptions
    var modelContext: ModelContext?

    private var notch: DynamicNotch<NotchRecordingView, EmptyView, EmptyView>?
    private var transcriptionTask: Task<Void, Never>?

    init() {
        coordinator = TranscriptionCoordinator(
            settings: settings,
            modelManager: modelManager
        )
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

    /// Check permissions on launch and surface a warning banner if any are revoked.
    func checkPermissionsOnLaunch() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let accessibilityGranted = AXIsProcessTrusted()

        if micStatus == .denied && !accessibilityGranted {
            permissionWarning = "Microphone and Accessibility permissions are missing. Go to Settings > Permissions to fix this."
        } else if micStatus == .denied {
            permissionWarning = "Microphone access was revoked. Go to Settings > Permissions to restore it."
        } else if !accessibilityGranted {
            permissionWarning = "Accessibility access is missing — auto-paste won't work. Go to Settings > Permissions to enable it."
        } else {
            permissionWarning = nil
        }
    }

    func dismissPermissionWarning() {
        permissionWarning = nil
    }

    /// Pre-warm the selected engine so first transcription is fast.
    /// Also starts system wake observation and keep-alive scheduling.
    func warmUpEngine() {
        coordinator.warmUpEngine()
        coordinator.observeSystemWake()
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
        // Pre-flight: check microphone permission before attempting CoreAudio
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            let message = micStatus == .denied
                ? "Microphone access denied. Open System Settings > Privacy > Microphone to grant access."
                : "Microphone access required. Grant it in Settings > Permissions."
            appStateLogger.warning("Recording blocked — microphone not authorized (status: \(String(describing: micStatus), privacy: .public))")
            state = .error(message)
            return
        }

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
            if settings.backgroundAudioMode == .muteSystemAudio {
                coordinator.audioControl.unmute()
            }
            if settings.backgroundAudioMode == .pauseMedia {
                coordinator.playbackController.resume()
            }
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
            if settings.backgroundAudioMode == .muteSystemAudio {
                coordinator.audioControl.unmute()
            }
            if settings.backgroundAudioMode == .pauseMedia {
                coordinator.playbackController.resume()
            }
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
                let pipelineResult = try await coordinator.transcribe(
                    audioFileURL: audioURL,
                    recordingDuration: recordingDuration
                )

                lastTranscription = pipelineResult.text

                // Surface accessibility warning if auto-paste fell back to clipboard-only
                if pipelineResult.pasteResult == .clipboardOnly {
                    pasteWarning = "Text copied to clipboard. Enable Accessibility in Settings for auto-paste."
                    pasteWarningDismissTask?.cancel()
                    pasteWarningDismissTask = Task {
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled else { return }
                        self.pasteWarning = nil
                    }
                }

                // Save to SwiftData
                saveTranscription(
                    text: pipelineResult.text,
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
