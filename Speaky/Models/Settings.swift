import Foundation
import os

private let settingsLogger = Logger.speaky(category: "Settings")

protocol SettingsStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: SettingsStore {}

/// Controls when the transcription engine is unloaded from memory after idle.
enum EngineUnloadOption: String, CaseIterable {
    case never
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes
    case oneHour

    var label: String {
        switch self {
        case .never: "Never"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        }
    }

    var description: String {
        switch self {
        case .never: "Model stays in memory for instant transcriptions"
        case .fiveMinutes: "Free memory after 5 minutes of inactivity"
        case .fifteenMinutes: "Free memory after 15 minutes of inactivity"
        case .thirtyMinutes: "Free memory after 30 minutes of inactivity"
        case .oneHour: "Free memory after 1 hour of inactivity"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .never: 0
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1800
        case .oneHour: 3600
        }
    }

    init(from seconds: TimeInterval) {
        switch seconds {
        case 300: self = .fiveMinutes
        case 900: self = .fifteenMinutes
        case 1800: self = .thirtyMinutes
        case 3600: self = .oneHour
        default: self = .never
        }
    }
}

/// Controls how background audio is handled during recording.
enum BackgroundAudioMode: String, CaseIterable {
    case off
    case pauseMedia
    case muteSystemAudio

    var label: String {
        switch self {
        case .off: "Off"
        case .pauseMedia: "Pause media"
        case .muteSystemAudio: "Mute system audio"
        }
    }

    var description: String {
        switch self {
        case .off: "Background audio continues during recording"
        case .pauseMedia: "Pauses media players (Spotify, YouTube, etc.)"
        case .muteSystemAudio: "Mutes all system audio without pausing media"
        }
    }
}

@Observable
final class AppSettings {
    private let store: any SettingsStore

    var selectedModelID: String {
        didSet { store.set(selectedModelID, forKey: "selectedModelID") }
    }
    var language: String {
        didSet { store.set(language, forKey: "language") }
    }
    var backgroundAudioMode: BackgroundAudioMode {
        didSet { store.set(backgroundAudioMode.rawValue, forKey: "backgroundAudioMode") }
    }
    var selectedAudioDevice: UInt32? {
        didSet {
            if let device = selectedAudioDevice {
                store.set(device, forKey: "selectedAudioDevice")
            } else {
                store.removeObject(forKey: "selectedAudioDevice")
            }
        }
    }
    var autoPaste: Bool {
        didSet { store.set(autoPaste, forKey: "autoPaste") }
    }
    var cleanUpTranscriptions: Bool {
        didSet { store.set(cleanUpTranscriptions, forKey: "cleanUpTranscriptions") }
    }
    var autoUnloadTimeout: TimeInterval {
        didSet { store.set(autoUnloadTimeout, forKey: "autoUnloadTimeout") }
    }
    var soundEffectsEnabled: Bool {
        didSet { store.set(soundEffectsEnabled, forKey: "soundEffectsEnabled") }
    }
    var cleanupInterval: String {
        didSet { store.set(cleanupInterval, forKey: "cleanupInterval") }
    }
    var cleanupIntervalEnum: CleanupInterval {
        CleanupInterval(rawValue: cleanupInterval) ?? .never
    }
    var engineUnloadOption: EngineUnloadOption {
        get { EngineUnloadOption(from: autoUnloadTimeout) }
        set { autoUnloadTimeout = newValue.seconds }
    }
    var selectedModel: TranscriptionModelInfo {
        TranscriptionModels.find(selectedModelID) ?? TranscriptionModels.available[0]
    }

    init(store: any SettingsStore = UserDefaults.standard) {
        self.store = store

        // Architecture-aware default model
        let defaultModel: String = {
            #if arch(arm64)
            return "parakeet-v3"
            #else
            return "whisper-small-q5_1"
            #endif
        }()

        // Migrate away from removed models (cloud engines, low-quality, incompatible mel bins)
        let savedModel = store.string(forKey: "selectedModelID") ?? defaultModel
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
            store.set(defaultModel, forKey: "selectedModelID")
        } else {
            self.selectedModelID = savedModel
        }
        self.language = store.string(forKey: "language") ?? "auto"
        if let savedMode = store.string(forKey: "backgroundAudioMode"),
           let mode = BackgroundAudioMode(rawValue: savedMode) {
            self.backgroundAudioMode = mode
        } else {
            self.backgroundAudioMode = .pauseMedia
        }
        self.autoPaste = store.object(forKey: "autoPaste") as? Bool ?? true
        self.cleanUpTranscriptions = store.object(forKey: "cleanUpTranscriptions") as? Bool ?? true
        // Default: 0 (never unload) — keeps model in memory for instant transcriptions.
        // Migrate users on the old 300s default to "never" since it caused cold-start issues.
        let savedTimeout = store.object(forKey: "autoUnloadTimeout") as? TimeInterval
        if savedTimeout == 300 || savedTimeout == nil {
            self.autoUnloadTimeout = 0
        } else {
            self.autoUnloadTimeout = savedTimeout!
        }
        self.soundEffectsEnabled = store.object(forKey: "soundEffectsEnabled") as? Bool ?? true
        self.cleanupInterval = store.string(forKey: "cleanupInterval") ?? "Never"
        let deviceVal = store.object(forKey: "selectedAudioDevice") as? UInt32
        self.selectedAudioDevice = deviceVal
    }
}
