import SwiftUI
import SwiftData
import AVFoundation
import os

private let historyLogger = Logger.speaky(category: "HistoryView")

struct HistoryView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Transcription.date, order: .reverse) private var transcriptions: [Transcription]
    @State private var playerState = AudioPlayerState()
    @State private var retranscribingID: UUID?
    @State private var copiedID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if transcriptions.isEmpty {
                emptyState
            } else {
                transcriptionList
            }
        }
        .navigationTitle("History")
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.recording.opacity(0.9)))
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            withAnimation { self.errorMessage = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut, value: errorMessage)
        .onDisappear {
            playerState.stop()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textTertiary)
            Text("No transcriptions yet")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Your transcriptions will appear here.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var transcriptionList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(transcriptions) { transcription in
                    transcriptionRow(transcription)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Row

    private func transcriptionRow(_ t: Transcription) -> some View {
        let isPlaying = playerState.playingID == t.id

        return VStack(alignment: .leading, spacing: 8) {
            // Header: date + duration + model
            HStack {
                Text(formattedDate(t.date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)

                Text("·")
                    .foregroundStyle(Theme.textTertiary)

                Text(formattedDuration(t.duration))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)

                Spacer()

                Text(t.modelID)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            // Text preview
            Text(t.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Mini player (shows when this row is playing)
            if isPlaying {
                miniPlayer
            }

            // Actions
            HStack(spacing: 12) {
                // Copy
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(t.text, forType: .string)
                    copiedID = t.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedID == t.id { copiedID = nil }
                    }
                } label: {
                    Label(
                        copiedID == t.id ? "Copied" : "Copy",
                        systemImage: copiedID == t.id ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(copiedID == t.id ? Theme.success : Theme.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.handCursor)

                // Play audio
                if let path = t.audioFileURL, FileManager.default.fileExists(atPath: path) {
                    Button {
                        if isPlaying {
                            playerState.stop()
                        } else {
                            playerState.play(path: path, id: t.id)
                        }
                    } label: {
                        Label(
                            isPlaying ? "Stop" : "Play",
                            systemImage: isPlaying ? "stop.fill" : "play.fill"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.amber)
                    }
                    .buttonStyle(.handCursor)
                }

                // Retranscribe
                if let audioPath = t.audioFileURL, FileManager.default.fileExists(atPath: audioPath) {
                    Button {
                        retranscribe(t)
                    } label: {
                        if retranscribingID == t.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Retranscribe", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.handCursor)
                    .disabled(retranscribingID == t.id)
                }

                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                .fill(Theme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Mini Player

    private var miniPlayer: some View {
        VStack(spacing: 6) {
            // Scrubber
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 4)

                    // Progress fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.amber)
                        .frame(width: max(0, geo.size.width * playerState.progress), height: 4)

                    // Scrub handle
                    Circle()
                        .fill(Theme.amber)
                        .frame(width: 10, height: 10)
                        .offset(x: max(0, geo.size.width * playerState.progress - 5))
                }
                .frame(height: 10)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            playerState.seek(to: fraction)
                        }
                )
            }
            .frame(height: 10)

            // Time labels
            HStack {
                Text(formatTime(playerState.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

                Spacer()

                Text(formatTime(playerState.totalDuration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func retranscribe(_ t: Transcription) {
        retranscribingID = t.id
        errorMessage = nil
        Task {
            defer { retranscribingID = nil }
            do {
                try await appState.retranscribe(t)
            } catch {
                historyLogger.error("Retranscription failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = "Retranscription failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Formatting

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today \(Self.timeFormatter.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday \(Self.timeFormatter.string(from: date))"
        } else {
            return Self.dateTimeFormatter.string(from: date)
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Player State

@Observable
@MainActor
final class AudioPlayerState {
    var playingID: UUID?
    var currentTime: TimeInterval = 0
    var totalDuration: TimeInterval = 0
    var progress: Double = 0

    private var player: AVAudioPlayer?
    private var updateTimer: Timer?
    private let delegate = PlayerDelegate()

    func play(path: String, id: UUID) {
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            p.delegate = delegate
            delegate.onFinish = { [weak self] in
                Task { @MainActor in
                    self?.stop()
                }
            }
            p.play()
            player = p
            playingID = id
            totalDuration = p.duration
            currentTime = 0
            progress = 0
            startTimer()
        } catch {
            historyLogger.error("Audio playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
        currentTime = 0
        totalDuration = 0
        progress = 0
        stopTimer()
    }

    func seek(to fraction: Double) {
        guard let player, totalDuration > 0 else { return }
        let time = fraction * totalDuration
        player.currentTime = time
        currentTime = time
        progress = fraction
    }

    private func startTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateProgress()
            }
        }
    }

    private func stopTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func updateProgress() {
        guard let player, totalDuration > 0 else { return }
        currentTime = player.currentTime
        progress = currentTime / totalDuration
    }
}

// MARK: - Player Delegate

private class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
