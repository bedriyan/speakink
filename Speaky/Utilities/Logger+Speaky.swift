import Foundation
import os

extension Logger {
    /// Create a logger scoped to the Speaky app with the given category.
    /// Uses the main bundle identifier when available, falling back to the hardcoded subsystem.
    static func speaky(category: String) -> Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bedriyan.speaky", category: category)
    }
}
