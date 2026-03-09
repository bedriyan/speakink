import SwiftUI
import AVFoundation

enum OnboardingStep: Int, CaseIterable {
    case permissions = 0
    case modelDownload
    case complete
}

struct OnboardingContainerView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var currentStep: OnboardingStep = .permissions

    var body: some View {
        ZStack {
            OnboardingBackgroundView()

            VStack(spacing: 0) {
                if currentStep != .complete {
                    OnboardingProgressView(
                        currentStep: currentStep.rawValue,
                        totalSteps: 2
                    )
                    .padding(.top, 32)
                }

                Spacer()

                Group {
                    switch currentStep {
                    case .permissions:
                        OnboardingPermissionsView {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                currentStep = .modelDownload
                            }
                        }
                    case .modelDownload:
                        OnboardingModelDownloadView {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                currentStep = .complete
                            }
                        }
                    case .complete:
                        OnboardingDoneView {
                            hasCompletedOnboarding = true
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                Spacer()
            }
        }
        .frame(minWidth: 500, minHeight: 440)
    }
}

// MARK: - Background

struct OnboardingBackgroundView: View {
    var body: some View {
        ZStack {
            Theme.bgDark

            RadialGradient(
                gradient: Gradient(colors: [
                    Theme.amber.opacity(0.12),
                    Theme.amber.opacity(0.04),
                    Color.clear
                ]),
                center: .top,
                startRadius: 30,
                endRadius: 500
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Progress Dots

struct OnboardingProgressView: View {
    let currentStep: Int
    let totalSteps: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Capsule()
                    .fill(index <= currentStep ? Theme.amber : Color.white.opacity(0.2))
                    .frame(width: index == currentStep ? 24 : 8, height: 6)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentStep)
            }
        }
    }
}

// MARK: - Combined Permissions Step

struct OnboardingPermissionsView: View {
    let onContinue: () -> Void

    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    @State private var pollTimer: Timer?
    @State private var showContent = false

    private var allGranted: Bool {
        micGranted && accessibilityGranted
    }

    var body: some View {
        VStack(spacing: 24) {
            SpeakyAnimationView(animation: allGranted ? .celebration : .neutral)
                .frame(width: 160, height: 160)

            VStack(spacing: 8) {
                Text("Permissions")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Speaky needs microphone access to record and accessibility access to paste text.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            // Permission cards — microphone first
            VStack(spacing: 12) {
                permissionCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    granted: micGranted,
                    denied: micDenied,
                    action: requestMicPermission
                )

                permissionCard(
                    icon: "accessibility",
                    title: "Accessibility",
                    granted: accessibilityGranted,
                    denied: false,
                    action: requestAccessibility
                )
            }
            .frame(maxWidth: 360)

            Spacer().frame(height: 8)

            VStack(spacing: 12) {
                Button(action: onContinue) {
                    Text("Continue")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 220, height: 48)
                        .background(Theme.amberGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.handCursor)
            }
        }
        .opacity(showContent ? 1 : 0)
        .offset(y: showContent ? 0 : 20)
        .onAppear {
            checkPermissions()
            startPolling()
            withAnimation(.easeOut(duration: 0.5)) { showContent = true }

            // Auto-advance if both already granted
            if allGranted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    onContinue()
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func permissionCard(icon: String, title: String, granted: Bool, denied: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(granted ? Theme.success : Theme.amber)
                .frame(width: 36)

            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            } else if denied {
                Button("Open Settings") {
                    openSystemSettings()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.amber)
                .buttonStyle(.handCursor)
            } else {
                Button("Grant") {
                    action()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.amber)
                .buttonStyle(.handCursor)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(granted ? Theme.success.opacity(0.06) : Theme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(granted ? Theme.success.opacity(0.2) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func checkPermissions() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        micGranted = micStatus == .authorized
        micDenied = micStatus == .denied
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Poll both permissions so the UI updates in real-time when user grants from System Settings
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let newMicStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                let newMicGranted = newMicStatus == .authorized
                let newMicDenied = newMicStatus == .denied
                let newAccessibility = AXIsProcessTrusted()

                if newMicGranted != micGranted || newMicDenied != micDenied || newAccessibility != accessibilityGranted {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        micGranted = newMicGranted
                        micDenied = newMicDenied
                        accessibilityGranted = newAccessibility
                    }
                }
            }
        }
    }

    private func requestMicPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied {
            openSystemSettings()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    micGranted = granted
                    micDenied = !granted
                }
            }
        }
    }

    private func requestAccessibility() {
        PasteService.requestAccessibility()
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Done Step

struct OnboardingDoneView: View {
    let onFinish: () -> Void
    @Environment(AppState.self) private var appState
    @State private var showContent = false

    var body: some View {
        VStack(spacing: 24) {
            SpeakyAnimationView(animation: .celebration)
                .frame(width: 160, height: 160)

            VStack(spacing: 8) {
                Text("You're all set!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Set a hotkey in Settings, then press it to record. Press again to stop and auto-paste.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Spacer().frame(height: 8)

            Button(action: onFinish) {
                Text("Start Using Speaky")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 240, height: 48)
                    .background(Theme.amberGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.handCursor)
        }
        .opacity(showContent ? 1 : 0)
        .offset(y: showContent ? 0 : 20)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { showContent = true }
        }
    }
}
