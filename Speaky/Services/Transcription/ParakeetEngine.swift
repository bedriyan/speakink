import Foundation
import FluidAudio
import os

private let logger = Logger.speaky(category: "ParakeetEngine")

/// Thread-safe transcription engine using an actor to serialize concurrent calls.
/// `AsrManager` and `VadManager` are non-Sendable third-party types, so they are
/// wrapped in `@unchecked Sendable` boxes to allow the actor to own them while
/// still providing compiler-enforced serialization of all access.
actor ParakeetEngine: TranscriptionEngine {
    private final class AsrBox: @unchecked Sendable {
        var manager: AsrManager?
    }

    private final class VadBox: @unchecked Sendable {
        var manager: VadManager?
    }

    private final class ModelsBox: @unchecked Sendable {
        var models: AsrModels?
    }

    private let asrBox = AsrBox()
    private let vadBox = VadBox()
    private let modelsBox = ModelsBox()
    private let version: AsrModelVersion

    init(version: AsrModelVersion = .v3) {
        self.version = version
    }

    func transcribe(audioFileURL: URL, language: String) async throws -> TranscriptionResult {
        try await ensureModelsLoaded()

        guard let asrManager = asrBox.manager else {
            throw TranscriptionError.modelNotLoaded
        }

        let audioSamples = try AudioFileLoader.loadSamples(from: audioFileURL)
        let durationSeconds = Double(audioSamples.count) / 16000.0

        var speechAudio = audioSamples

        // Use VAD for longer audio to filter non-speech segments
        if durationSeconds >= 20.0 {
            if vadBox.manager == nil {
                let vadConfig = VadConfig(defaultThreshold: 0.7)
                vadBox.manager = try? await VadManager(config: vadConfig)
            }
            if let vadManager = vadBox.manager {
                do {
                    let segments = try await vadManager.segmentSpeechAudio(audioSamples)
                    if !segments.isEmpty {
                        speechAudio = segments.flatMap { $0 }
                    }
                } catch {
                    logger.notice("VAD segmentation failed; using full audio: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Pad with 1 second of silence to help capture final punctuation
        let trailingSilenceSamples = 16_000
        let maxSingleChunkSamples = 240_000
        if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
            speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
        }

        logger.info("Transcribing \(speechAudio.count) samples (\(String(format: "%.1f", Double(speechAudio.count) / 16000.0))s)")
        let result = try await asrManager.transcribe(speechAudio)
        logger.info("Transcription result: \(result.text.count) chars — \"\(result.text.prefix(100), privacy: .public)\"")

        return TranscriptionResult(
            text: result.text,
            language: language == "auto" ? nil : language,
            duration: durationSeconds,
            segments: []
        )
    }

    // MARK: - Private

    private func ensureModelsLoaded() async throws {
        if asrBox.manager != nil { return }

        let models: AsrModels
        if let cached = modelsBox.models {
            models = cached
        } else {
            do {
                models = try await AsrModels.loadFromCache(configuration: nil, version: version)
                modelsBox.models = models
                logger.info("Parakeet models loaded for first time (version: \(String(describing: self.version), privacy: .public))")
            } catch {
                logger.error("Failed to load Parakeet models: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        asrBox.manager = manager
    }

    func warmUp() async throws {
        try await ensureModelsLoaded()
        logger.info("Parakeet engine warmed up — models loaded and ready")
    }

    func cleanup() {
        logger.info("Parakeet engine cleanup")
        asrBox.manager?.cleanup()
        asrBox.manager = nil
        vadBox.manager = nil
    }
}
