import Foundation
import os

private let settingsLogger = Logger.speaky(category: "Settings")

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
    var selectedModelID: String {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "selectedModelID") }
    }
    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    var backgroundAudioMode: BackgroundAudioMode {
        didSet { UserDefaults.standard.set(backgroundAudioMode.rawValue, forKey: "backgroundAudioMode") }
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
    var engineUnloadOption: EngineUnloadOption {
        get { EngineUnloadOption(from: autoUnloadTimeout) }
        set { autoUnloadTimeout = newValue.seconds }
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
        if let savedMode = UserDefaults.standard.string(forKey: "backgroundAudioMode"),
           let mode = BackgroundAudioMode(rawValue: savedMode) {
            self.backgroundAudioMode = mode
        } else {
            self.backgroundAudioMode = .pauseMedia
        }
        self.autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true
        self.cleanUpTranscriptions = UserDefaults.standard.object(forKey: "cleanUpTranscriptions") as? Bool ?? true
        // Default: 0 (never unload) — keeps model in memory for instant transcriptions.
        // Migrate users on the old 300s default to "never" since it caused cold-start issues.
        let savedTimeout = UserDefaults.standard.object(forKey: "autoUnloadTimeout") as? TimeInterval
        if savedTimeout == 300 || savedTimeout == nil {
            self.autoUnloadTimeout = 0
        } else {
            self.autoUnloadTimeout = savedTimeout ?? 0
        }
        self.soundEffectsEnabled = UserDefaults.standard.object(forKey: "soundEffectsEnabled") as? Bool ?? true
        self.checkForUpdates = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true
        self.cleanupInterval = UserDefaults.standard.string(forKey: "cleanupInterval") ?? "Never"
        let deviceVal = UserDefaults.standard.object(forKey: "selectedAudioDevice") as? UInt32
        self.selectedAudioDevice = deviceVal
    }
}
