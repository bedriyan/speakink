import SwiftUI

struct OnboardingModelDownloadView: View {
    @Environment(AppState.self) private var appState
    let onContinue: () -> Void

    @State private var isDownloading = false
    @State private var isDownloaded = false
    @State private var downloadError: String?
    @State private var showContent = false

    private let recommendedModel: TranscriptionModelInfo = {
        #if arch(arm64)
        return TranscriptionModels.available.first { $0.id == "parakeet-v3" }
            ?? TranscriptionModels.available[0]
        #else
        return TranscriptionModels.available.first { $0.id == "whisper-medium-q5_0" }
            ?? TranscriptionModels.available[0]
        #endif
    }()

    var body: some View {
        VStack(spacing: 24) {
            SpeakyAnimationView(animation: isDownloaded ? .celebration : .listening)
                .frame(width: 160, height: 160)

            VStack(spacing: 8) {
                Text("Downloading AI Model")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Setting up \(recommendedModel.name) for fast, private transcription.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            // Model info card
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recommendedModel.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        HStack(spacing: 8) {
                            Label(recommendedModel.size ?? "", systemImage: "arrow.down.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)

                            Label("Local & Private", systemImage: "lock.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.success.opacity(0.8))
                        }
                    }

                    Spacer()

                    if isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.success)
                    }
                }

                if isDownloading {
                    let progress = appState.modelManager.downloadProgress[recommendedModel.id] ?? 0

                    VStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(0.08))

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.amberGradient)
                                    .frame(width: geo.size.width * progress)
                                    .animation(.linear(duration: 0.3), value: progress)
                            }
                        }
                        .frame(height: 6)

                        HStack {
                            Text("Downloading...")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.amber)
                        }
                    }
                }

                if let error = downloadError {
                    VStack(spacing: 8) {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.recording)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Retry") {
                            startDownload()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.amber)
                        .buttonStyle(.handCursor)
                    }
                }
            }
            .padding(16)
            .background(Theme.amber.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.amber.opacity(0.15), lineWidth: 1))
            .frame(maxWidth: 400)

            Spacer().frame(height: 8)

            if isDownloaded {
                Button(action: {
                    appState.settings.selectedModelID = recommendedModel.id
                    onContinue()
                }) {
                    Text("Continue")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 220, height: 48)
                        .background(Theme.amberGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.handCursor)
            } else if isDownloading {
                Text("Please wait...")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }

            if !isDownloading && !isDownloaded {
                Button(action: onContinue) {
                    Text("Skip for now")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.handCursor)
            }
        }
        .opacity(showContent ? 1 : 0)
        .offset(y: showContent ? 0 : 20)
        .onAppear {
            isDownloaded = appState.modelManager.isDownloaded(recommendedModel)
            withAnimation(.easeOut(duration: 0.5)) { showContent = true }

            // Auto-start download if not yet downloaded
            if !isDownloaded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if !isDownloaded && !isDownloading {
                        startDownload()
                    }
                }
            }
        }
    }

    private func startDownload() {
        isDownloading = true
        downloadError = nil

        Task {
            do {
                if recommendedModel.type == .parakeet {
                    _ = try await appState.modelManager.downloadParakeetModel(recommendedModel)
                } else {
                    guard let url = recommendedModel.downloadURL, let fileName = recommendedModel.fileName else { return }
                    _ = try await appState.modelManager.downloadModel(
                        id: recommendedModel.id,
                        from: url,
                        fileName: fileName
                    )
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    isDownloaded = true
                    isDownloading = false
                }
            } catch {
                isDownloading = false
                downloadError = error.localizedDescription
            }
        }
    }
}
