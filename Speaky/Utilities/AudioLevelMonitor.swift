import Foundation

final class AudioLevelMonitor: @unchecked Sendable {
    private let onLevels: @Sendable ([Float]) -> Void
    private var levels: [Float]
    private let barCount: Int
    private var lastSmoothedLevel: Float = 0

    // Throttle: only emit updates at ~30fps to avoid overwhelming SwiftUI
    // CoreAudio callbacks fire much faster than AVAudioEngine taps
    private var lastEmitTime: UInt64 = 0
    private static let minEmitInterval: UInt64 = 33_000_000 // ~30fps in nanoseconds

    init(barCount: Int = 30, onLevels: @escaping @Sendable ([Float]) -> Void) {
        self.barCount = barCount
        self.levels = Array(repeating: 0, count: barCount)
        self.onLevels = onLevels
    }

    func process(samples: [Float]) {
        guard !samples.isEmpty else { return }

        // Calculate RMS
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))

        // Convert to dB and normalize to 0…1
        let db = 20 * log10(max(rms, 1e-10))
        let raw = max(0, min(1, (db + 60) / 60))

        // Heavy EMA smoothing for natural, calm waveform movement
        let smoothed: Float
        if raw > lastSmoothedLevel {
            // Rise: moderate speed for responsiveness without jumpiness
            smoothed = lastSmoothedLevel * 0.5 + raw * 0.5
        } else {
            // Fall: slow decay for smooth, natural feel
            smoothed = lastSmoothedLevel * 0.75 + raw * 0.25
        }
        lastSmoothedLevel = smoothed

        // Throttle UI updates to ~30fps
        let now = mach_absolute_time()
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let elapsed = (now - lastEmitTime) * UInt64(info.numer) / UInt64(info.denom)
        guard elapsed >= Self.minEmitInterval else { return }
        lastEmitTime = now

        // Shift levels left and add new value
        levels.removeFirst()
        levels.append(smoothed)

        onLevels(levels)
    }
}
