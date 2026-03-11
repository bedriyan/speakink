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

    // Cache timebase info — it never changes and calling the syscall per-callback is wasteful
    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init(barCount: Int = 30, onLevels: @escaping @Sendable ([Float]) -> Void) {
        self.barCount = barCount
        self.levels = Array(repeating: 0, count: barCount)
        self.onLevels = onLevels
    }

    /// Process audio samples from a raw pointer — avoids heap allocation on the audio thread.
    func process(buffer: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }

        // Calculate RMS directly from pointer
        var sumOfSquares: Float = 0
        for i in 0..<count {
            let s = buffer[i]
            sumOfSquares += s * s
        }
        let rms = sqrt(sumOfSquares / Float(count))

        processLevel(rms: rms)
    }

    /// Process audio samples from an array (convenience, used in tests).
    func process(samples: [Float]) {
        guard !samples.isEmpty else { return }

        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))

        processLevel(rms: rms)
    }

    private func processLevel(rms: Float) {
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

        // Throttle UI updates to ~30fps (using cached timebase)
        let now = mach_absolute_time()
        let info = Self.timebaseInfo
        let elapsed = (now - lastEmitTime) * UInt64(info.numer) / UInt64(info.denom)
        guard elapsed >= Self.minEmitInterval else { return }
        lastEmitTime = now

        // Shift levels left and add new value
        levels.removeFirst()
        levels.append(smoothed)

        onLevels(levels)
    }
}
