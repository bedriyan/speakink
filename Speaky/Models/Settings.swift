import Foundation
import os

private let settingsLogger = Logger.speaky(category: "Settings")

@Observable
final class AppSettings {
    var selectedModelID: String {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "selectedModelID") }
    }
    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    var muteSystemAudio: Bool {
        didSet { UserDefaults.standard.set(muteSystemAudio, forKey: "muteSystemAudio") }
    }
    var selectedAudioDevice: UInt32? {
        didSet {
            if let device = selectedAudioDevice {
                UserDefaults.standard.set(device, forKey: "selectedAudioDevice")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedAudioDevice")
            }
        }
    }
    var autoPaste: Bool {
        didSet { UserDefaults.standard.set(autoPaste, forKey: "autoPaste") }
    }
    var cleanUpTranscriptions: Bool {
        didSet { UserDefaults.standard.set(cleanUpTranscriptions, forKey: "cleanUpTranscriptions") }
    }
    var autoUnloadTimeout: TimeInterval {
        didSet { UserDefaults.standard.set(autoUnloadTimeout, forKey: "autoUnloadTimeout") }
    }
    var soundEffectsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEffectsEnabled, forKey: "soundEffectsEnabled") }
    }
    var checkForUpdates: Bool {
        didSet { UserDefaults.standard.set(checkForUpdates, forKey: "checkForUpdates") }
    }
    var cleanupInterval: String {
        didSet { UserDefaults.standard.set(cleanupInterval, forKey: "cleanupInterval") }
    }
    var cleanupIntervalEnum: CleanupInterval {
        CleanupInterval(rawValue: cleanupInterval) ?? .never
    }
    var selectedModel: TranscriptionModelInfo {
        TranscriptionModels.find(selectedModelID) ?? TranscriptionModels.available[0]
    }

    init() {
        // Architecture-aware default model
        let defaultModel: String = {
            #if arch(arm64)
            return "parakeet-v3"
            #else
            return "whisper-small-q5_1"
            #endif
        }()

        // Migrate away from removed models (cloud engines, low-quality, incompatible mel bins)
        let savedModel = UserDefaults.standard.string(forKey: "selectedModelID") ?? defaultModel
        let removedModelIDs: Set<String> = [
            "deepgram-nova-3",
            "whisper-large-v3-turbo", "whisper-large-v3"
        ]

        #if !arch(arm64)
        // Intel: Parakeet requires Apple Neural Engine, migrate to Whisper
        let intelIncompatible: Set<String> = ["parakeet-v3"]
        let allRemoved = removedModelIDs.union(intelIncompatible)
        #else
        let allRemoved = removedModelIDs
        #endif

        if allRemoved.contains(savedModel) {
            self.selectedModelID = defaultModel
            UserDefaults.standard.set(defaultModel, forKey: "selectedModelID")
        } else {
            self.selectedModelID = savedModel
        }
        self.language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        self.muteSystemAudio = UserDefaults.standard.bool(forKey: "muteSystemAudio")
        self.autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true
        self.cleanUpTranscriptions = UserDefaults.standard.object(forKey: "cleanUpTranscriptions") as? Bool ?? true
        self.autoUnloadTimeout = UserDefaults.standard.object(forKey: "autoUnloadTimeout") as? TimeInterval ?? 300
        self.soundEffectsEnabled = UserDefaults.standard.object(forKey: "soundEffectsEnabled") as? Bool ?? true
        self.checkForUpdates = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true
        self.cleanupInterval = UserDefaults.standard.string(forKey: "cleanupInterval") ?? "Never"
        let deviceVal = UserDefaults.standard.object(forKey: "selectedAudioDevice") as? UInt32
        self.selectedAudioDevice = deviceVal
    }
}
