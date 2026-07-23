import Foundation
import SwiftData

enum PersistenceContainer {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment.keys.contains {
            $0.hasPrefix("XCTest")
        }
    }

    static func make(isStoredInMemoryOnly: Bool? = nil) throws -> ModelContainer {
        let configuration: ModelConfiguration
        let useInMemoryStore = isStoredInMemoryOnly ?? isRunningTests

        if useInMemoryStore {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            configuration = ModelConfiguration(url: Constants.transcriptionStorePath)
        }

        return try ModelContainer(
            for: Transcription.self,
            configurations: configuration
        )
    }
}
