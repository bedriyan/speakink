import SwiftUI
import AVFoundation
@preconcurrency import KeyboardShortcuts

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var inputDevices: [AudioControlService.AudioDeviceInfo] = []
    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    @State private var pollTimer: Timer?
    @State private var groqAPIKey: String = ""
    @State private var showAdvanced = false
    @State private var showGroqAlert = false

    var body: some View {
        @Bindable var settings = appState.settings

        Form {
            // Hotkey
            Section("Hotkey") {
                HotkeyRecorderRow()

                Text("Supports push-to-talk (hold) and hands-free (tap) modes.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            // Language
            Section("Language") {
                LanguagePicker(selection: Binding(
                    get: { settings.language },
                    set: { settings.language = $0 }
                ))
            }

            // Behavior
            Section("Behavior") {
                Toggle("Auto-paste after transcription", isOn: Binding(
                    get: { settings.autoPaste },
                    set: { settings.autoPaste = $0 }
                ))
                .contentShape(Rectangle())
                .onTapGesture { settings.autoPaste.toggle() }

                Toggle("Clean up filler words", isOn: Binding(
                    get: { settings.cleanUpTranscriptions },
                    set: { settings.cleanUpTranscriptions = $0 }
                ))
                .contentShape(Rectangle())
                .onTapGesture { settings.cleanUpTranscriptions.toggle() }

                Toggle("Enable sound effects", isOn: Binding(
                    get: { settings.soundEffectsEnabled },
                    set: { settings.soundEffectsEnabled = $0 }
                ))
                .contentShape(Rectangle())
                .onTapGesture { settings.soundEffectsEnabled.toggle() }

                Toggle("Check for updates automatically", isOn: Binding(
                    get: { settings.checkForUpdates },
                    set: { newValue in
                        settings.checkForUpdates = newValue
                        if newValue {
                            appState.updateService.startPeriodicChecks()
                        } else {
                            appState.updateService.stopPeriodicChecks()
                        }
                    }
                ))
                .contentShape(Rectangle())
                .onTapGesture {
                    let newValue = !settings.checkForUpdates
                    settings.checkForUpdates = newValue
                    if newValue {
                        appState.updateService.startPeriodicChecks()
                    } else {
                        appState.updateService.stopPeriodicChecks()
                    }
                }
            }

            // Audio Input
            Section("Audio Input") {
                Picker("Input Device", selection: Binding(
                    get: { settings.selectedAudioDevice },
                    set: { settings.selectedAudioDevice = $0 }
                )) {
                    Text("Auto (Built-in Mic)").tag(nil as UInt32?)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.id as UInt32?)
                    }
                }

                Toggle("Mute system audio while recording", isOn: Binding(
                    get: { settings.muteSystemAudio },
                    set: { settings.muteSystemAudio = $0 }
                ))
                .contentShape(Rectangle())
                .onTapGesture { settings.muteSystemAudio.toggle() }
            }

            // Permissions
            Section("Permissions") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Microphone Access")
                            .font(.body)
                        Text("Required for recording audio.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if micGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                    } else if micDenied {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .foregroundStyle(Theme.amber)
                    } else {
                        Button("Grant Access") {
                            AVCaptureDevice.requestAccess(for: .audio) { granted in
                                DispatchQueue.main.async {
                                    micGranted = granted
                                    micDenied = !granted
                                }
                            }
                        }
                        .foregroundStyle(Theme.amber)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility Access")
                            .font(.body)
                        Text("Required for auto-paste.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                    } else {
                        Button("Grant Access") {
                            PasteService.requestAccessibility()
                        }
                        .foregroundStyle(Theme.amber)
                    }
                }
            }

            // Advanced (collapsed by default)
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    HStack {
                        Text("Advanced")
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.handCursor)

                if showAdvanced {
                    // AI Model
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI Model")
                            .font(.subheadline.bold())
                            .foregroundStyle(Theme.textPrimary)

                        // Current model indicator
                        HStack {
                            Text(appState.settings.selectedModel.name)
                                .font(.subheadline)
                                .foregroundStyle(Theme.amber)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("Speed")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                                RatingDots(rating: appState.settings.selectedModel.speedRating, color: Theme.amber)
                            }
                            HStack(spacing: 4) {
                                Text("Accuracy")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                                RatingDots(rating: appState.settings.selectedModel.accuracyRating, color: Theme.success)
                            }
                        }
                        .padding(10)
                        .background(Theme.amber.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.top, 8)

                    // Model list
                    ForEach(TranscriptionModels.available) { model in
                        modelRow(model)
                    }

                    // Import custom model
                    Button {
                        importCustomModel()
                    } label: {
                        Label("Import Custom Whisper Model", systemImage: "square.and.arrow.down")
                            .font(.subheadline)
                            .foregroundStyle(Theme.amber)
                    }
                    .buttonStyle(.handCursor)
                    .padding(.top, 4)

                    Divider()
                        .padding(.vertical, 4)

                    // Groq API Key
                    HStack {
                        Text("Groq API Key")
                            .font(.subheadline)
                        Spacer()
                        SecureField("sk-...", text: $groqAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onChange(of: groqAPIKey) { _, newValue in
                                if newValue.isEmpty {
                                    KeychainHelper.delete(service: Constants.keychainService, account: "groq-api-key")
                                } else {
                                    KeychainHelper.save(service: Constants.keychainService, account: "groq-api-key", value: newValue)
                                }
                            }
                    }

                    Text("Free API key from [groq.com](https://console.groq.com). Required for Groq cloud transcription.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)

                    Divider()
                        .padding(.vertical, 4)

                    // Storage
                    Picker("Auto-delete older than", selection: Binding(
                        get: { settings.cleanupIntervalEnum },
                        set: { settings.cleanupInterval = $0.rawValue }
                    )) {
                        ForEach(CleanupInterval.allCases, id: \.self) { interval in
                            Text(interval.rawValue).tag(interval)
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // Reset onboarding
                    Button("Reset Onboarding") {
                        hasCompletedOnboarding = false
                    }
                    .foregroundStyle(Theme.amber)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .alert("Groq API Key Required", isPresented: $showGroqAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Add your Groq API key in Settings → Advanced before selecting this model.")
        }
        .onAppear {
            inputDevices = AudioControlService.inputDevices()
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            micGranted = micStatus == .authorized
            micDenied = micStatus == .denied
            accessibilityGranted = PasteService.checkAccessibility()
            groqAPIKey = KeychainHelper.read(service: Constants.keychainService, account: "groq-api-key") ?? ""
            pollTimer = Timer.scheduledTimer(withTimeInterval: Constants.Timing.permissionPollInterval, repeats: true) { _ in
                Task { @MainActor in
                    let newAccessibility = PasteService.checkAccessibility()
                    if newAccessibility != accessibilityGranted {
                        accessibilityGranted = newAccessibility
                    }
                    let newMicStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    let newMicGranted = newMicStatus == .authorized
                    let newMicDenied = newMicStatus == .denied
                    if newMicGranted != micGranted || newMicDenied != micDenied {
                        micGranted = newMicGranted
                        micDenied = newMicDenied
                    }
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - Model Row

    private func modelRow(_ model: TranscriptionModelInfo) -> some View {
        let isSelected = model.id == appState.settings.selectedModelID
        let isDownloaded = appState.modelManager.isDownloaded(model) || model.type == .groq
        let progress = appState.modelManager.downloadProgress[model.id]

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? Theme.amber : Theme.textPrimary)
                    if let size = model.size {
                        Text(size)
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Text("Speed")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                        RatingDots(rating: model.speedRating, color: Theme.amber)
                    }
                    HStack(spacing: 2) {
                        Text("Accuracy")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                        RatingDots(rating: model.accuracyRating, color: Theme.success)
                    }
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                    .font(.system(size: 14))
            } else if isDownloaded {
                Button("Select") {
                    selectModel(model)
                }
                .font(.caption)
                .foregroundStyle(Theme.amber)
                .buttonStyle(.handCursor)
            } else if let prog = progress, prog < 1.0 {
                HStack(spacing: 6) {
                    ProgressView(value: prog)
                        .tint(Theme.amber)
                        .frame(width: 60)
                    Text("\(Int(prog * 100))%")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Button("Download") {
                    downloadModel(model)
                }
                .font(.caption)
                .foregroundStyle(Theme.amber)
                .buttonStyle(.handCursor)
            }

            // Delete button for downloaded non-Groq models
            if isDownloaded && model.type != .groq && !isSelected {
                Button {
                    deleteModel(model)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.6))
                }
                .buttonStyle(.handCursor)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Actions

    private func selectModel(_ model: TranscriptionModelInfo) {
        if model.type == .groq {
            let hasKey = KeychainHelper.read(service: Constants.keychainService, account: "groq-api-key")
            if hasKey == nil || hasKey?.isEmpty == true {
                showGroqAlert = true
                return
            }
        }
        appState.settings.selectedModelID = model.id
    }

    private func downloadModel(_ model: TranscriptionModelInfo) {
        Task {
            if model.type == .parakeet {
                _ = try? await appState.modelManager.downloadParakeetModel(model)
            } else {
                guard let url = model.downloadURL, let fileName = model.fileName else { return }
                _ = try? await appState.modelManager.downloadModel(id: model.id, from: url, fileName: fileName)
            }
        }
    }

    private func deleteModel(_ model: TranscriptionModelInfo) {
        if model.type == .parakeet {
            appState.modelManager.deleteParakeetModel(model)
        } else {
            try? appState.modelManager.deleteModel(model)
        }
    }

    private func importCustomModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "bin")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            if let path = try? appState.modelManager.importCustomModel(from: url) {
                let model = TranscriptionModels.customWhisper(path: path)
                appState.settings.selectedModelID = model.id
            }
        }
    }
}

// MARK: - Rating Dots

struct RatingDots: View {
    let rating: Int
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Circle()
                    .fill(i <= rating ? color : color.opacity(0.2))
                    .frame(width: 5, height: 5)
            }
        }
    }
}

// MARK: - Hotkey Recorder

struct HotkeyRecorderRow: View {
    @State private var isRecording = false
    @State private var currentShortcut: KeyboardShortcuts.Shortcut?
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(spacing: 12) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                HStack(spacing: 10) {
                    if isRecording {
                        Circle()
                            .fill(Theme.recording)
                            .frame(width: 8, height: 8)

                        Text("Press any key combination...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                    } else if let shortcut = currentShortcut {
                        Image(systemName: "keyboard")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.amber)

                        Text(shortcut.description)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                    } else {
                        Image(systemName: "keyboard")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)

                        Text("Click to record shortcut")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Spacer()

                    if isRecording {
                        Text("ESC to cancel")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isRecording ? Theme.amber.opacity(0.08) : Theme.bgCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isRecording ? Theme.amber.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1)
                )
            }
            .buttonStyle(.handCursor)

            if currentShortcut != nil {
                Button {
                    KeyboardShortcuts.reset(.toggleRecording)
                    currentShortcut = nil
                } label: {
                    Text("Reset Shortcut")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.handCursor)
            }
        }
        .onAppear {
            currentShortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        }
    }

    private func startRecording() {
        isRecording = true
        // Use the built-in recorder by temporarily enabling it
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // ESC
                stopRecording()
                return nil
            }

            if let shortcut = KeyboardShortcuts.Shortcut(event: event) {
                KeyboardShortcuts.setShortcut(shortcut, for: .toggleRecording)
                currentShortcut = shortcut
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Notification for tab switching (kept for compatibility)

extension Notification.Name {
    static let switchToSettings = Notification.Name("switchToSettings")
}
