import Foundation
import AVFoundation

enum Constants {
    static let appSupportPath: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speaky", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let modelsPath = appSupportPath.appendingPathComponent("Models", isDirectory: true)

    static let recordingsPath: URL = {
        let url = appSupportPath.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let supportedAudioExtensions: Set<String> = ["wav", "mp3", "m4a", "mp4", "flac", "ogg", "aac", "wma", "webm"]

    enum Timing {
        static let pasteboardReadyDelay: TimeInterval = 0.08
        static let pasteboardRestoreDelay: TimeInterval = 0.4
        static let hotkeyBriefPressThreshold: TimeInterval = 0.4
        static let permissionPollInterval: TimeInterval = 3.0
        static let cancelWarningDuration: TimeInterval = 2.0
        static let transcriptionTimeout: TimeInterval = 120
    }

    enum Audio {
        static let bufferSize: AVAudioFrameCount = 4096
        static let sampleRate: Double = 16000
    }

    enum KeyCode {
        static let escape: UInt16 = 53
    }

    static let keychainService = "speaky"

    enum Groq {
        static let apiURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        static let modelName = "whisper-large-v3-turbo"
    }

    static let supportedLanguages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("tr", "Turkish"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("sv", "Swedish"),
        ("uk", "Ukrainian"),
    ]
}
