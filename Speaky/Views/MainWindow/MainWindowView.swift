import SwiftUI
@preconcurrency import KeyboardShortcuts

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgDark.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top bar
                    HStack {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.handCursor)
                        .help("Settings")
                        .accessibilityLabel("Settings")

                        Button {
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.handCursor)
                        .help("History")
                        .accessibilityLabel("History")

                        Spacer()

                        Text("Speaky")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    if let warning = appState.permissionWarning {
                        PermissionWarningBanner(message: warning) {
                            showSettings = true
                        } onDismiss: {
                            appState.dismissPermissionWarning()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.3), value: appState.permissionWarning)
                    }

                    if let pasteWarning = appState.pasteWarning {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundStyle(Theme.amber)
                                .font(.system(size: 12))
                            Text(pasteWarning)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.amber.opacity(0.06))
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: appState.pasteWarning)
                    }

                    Spacer()

                    // Record button
                    recordButton

                    // Status
                    statusText
                        .padding(.top, 20)

                    Spacer()

                    // Last transcription
                    if let text = appState.lastTranscription {
                        lastTranscriptionCard(text)
                            .padding(.horizontal, 24)
                    }

                    // Footer info
                    footerInfo
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(isPresented: $showHistory) {
                HistoryView()
            }
        }
    }

    // MARK: - Record Button

    private var recordButton: some View {
        Button {
            appState.toggleRecording()
        } label: {
            SpeakyAnimationView(
                animation: activeSpeakyAnimation,
                onOneShotComplete: {
                    appState.showingCelebration = false
                }
            )
            .frame(width: 220, height: 220)
        }
        .buttonStyle(.handCursor)
        .accessibilityLabel(appState.isRecording ? "Stop recording" : appState.isTranscribing ? "Cancel transcription" : "Start recording")
        .animation(.easeInOut(duration: 0.3), value: appState.state)
    }

    private var activeSpeakyAnimation: SpeakyAnimation {
        if appState.showingCelebration { return .celebration }
        return appState.state.speakyAnimation
    }

    // MARK: - Status

    private var statusText: some View {
        VStack(spacing: 4) {
            Text(statusLabel)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(statusColor)

            if case .error(let msg) = appState.state {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.recording.opacity(0.8))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            } else {
                Text(hotkeyHint)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var statusLabel: String {
        switch appState.state {
        case .idle: "Ready"
        case .recording: "Listening..."
        case .transcribing: "Transcribing... (click to cancel)"
        case .error: "Error"
        }
    }

    private var statusColor: Color {
        switch appState.state {
        case .idle: Theme.textSecondary
        case .recording: Theme.amber
        case .transcribing: Theme.amber
        case .error: Theme.recording
        }
    }

    private var hotkeyHint: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            return shortcut.description
        }
        return "Set a shortcut in Settings"
    }

    // MARK: - Last Transcription

    private func lastTranscriptionCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last transcription")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(copied ? Theme.success : Theme.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.handCursor)
                .help("Copy to clipboard")
                .accessibilityLabel("Copy to clipboard")
            }

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footerInfo: some View {
        HStack(spacing: 12) {
            Label(appState.settings.selectedModel.name, systemImage: "cpu")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            Text("·")
                .foregroundStyle(Theme.textTertiary)

            Label(languageLabel, systemImage: "globe")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var languageLabel: String {
        appState.settings.language == "auto" ? "Auto" : appState.settings.language.capitalized
    }
}

// MARK: - Permission Warning Banner

struct PermissionWarningBanner: View {
    let message: String
    let onSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.amber)
                .font(.system(size: 14))

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            Spacer()

            Button("Fix") {
                onSettings()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.amber)
            .buttonStyle(.handCursor)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.handCursor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.amber.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.amber.opacity(0.2), lineWidth: 1)
        )
    }
}
