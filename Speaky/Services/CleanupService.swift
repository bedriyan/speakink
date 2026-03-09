import Foundation
import SwiftData
import os

enum CleanupInterval: String, CaseIterable {
    case never = "Never"
    case thirtyMinutes = "30 Minutes"
    case oneHour = "1 Hour"
    case oneDay = "1 Day"
    case sevenDays = "7 Days"
    case thirtyDays = "30 Days"

    var timeInterval: TimeInterval? {
        switch self {
        case .never: nil
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        }
    }
}

enum CleanupService {
    private static let logger = Logger.speaky(category: "CleanupService")

    @MainActor
    static func performCleanup(context: ModelContext, interval: CleanupInterval) {
        guard let seconds = interval.timeInterval else { return }
        let cutoff = Date().addingTimeInterval(-seconds)

        let predicate = #Predicate<Transcription> { $0.date < cutoff }
        let descriptor = FetchDescriptor<Transcription>(predicate: predicate)

        do {
            let old = try context.fetch(descriptor)
            guard !old.isEmpty else { return }

            for transcription in old {
                if let path = transcription.audioFileURL {
                    try? FileManager.default.removeItem(atPath: path)
                }
                context.delete(transcription)
            }
            try context.save()
            logger.info("Cleaned up \(old.count) transcription(s) older than \(interval.rawValue)")
        } catch {
            logger.warning("Cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
