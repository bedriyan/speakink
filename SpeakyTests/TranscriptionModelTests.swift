import Testing
@testable import Speaky

@Suite("TranscriptionModels")
struct TranscriptionModelTests {

    @Test("find returns model for valid ID")
    func findValidID() {
        let model = TranscriptionModels.find("groq-whisper")
        #expect(model != nil)
        #expect(model?.type == .groq)
    }

    @Test("find returns nil for unknown ID")
    func findUnknownID() {
        #expect(TranscriptionModels.find("nonexistent-model") == nil)
    }

    @Test("recommended models are subset of available")
    func recommendedSubsetOfAvailable() {
        let availableIDs = Set(TranscriptionModels.available.map(\.id))
        for model in TranscriptionModels.recommended {
            #expect(availableIDs.contains(model.id))
        }
    }

    @Test("expanded models exclude recommended")
    func expandedExcludesRecommended() {
        let recommendedIDs = Set(TranscriptionModels.recommended.map(\.id))
        for model in TranscriptionModels.expanded {
            #expect(!recommendedIDs.contains(model.id))
        }
    }

    @Test("all models have valid ratings")
    func validRatings() {
        for model in TranscriptionModels.all {
            #expect((1...5).contains(model.speedRating), "Speed rating out of range for \(model.id)")
            #expect((1...5).contains(model.accuracyRating), "Accuracy rating out of range for \(model.id)")
        }
    }

    @Test("groq models require API key")
    func groqRequiresAPIKey() {
        for model in TranscriptionModels.all where model.type == .groq {
            #expect(TranscriptionModels.requiresAPIKey(model))
        }
    }

    @Test("non-groq models do not require API key")
    func nonGroqNoAPIKey() {
        for model in TranscriptionModels.all where model.type != .groq {
            #expect(!TranscriptionModels.requiresAPIKey(model))
        }
    }

    @Test("whisper models have download URLs and file names")
    func whisperModelsHaveURLs() {
        for model in TranscriptionModels.all where model.type == .whisper {
            #expect(model.downloadURL != nil, "Missing download URL for \(model.id)")
            #expect(model.fileName != nil, "Missing file name for \(model.id)")
        }
    }

    @Test("custom whisper model creates valid info")
    func customWhisperModel() {
        let model = TranscriptionModels.customWhisper(path: "/tmp/my-model.bin")
        #expect(model.id == "custom-my-model.bin")
        #expect(model.type == .whisper)
        #expect(model.fileName == "my-model.bin")
    }
}
