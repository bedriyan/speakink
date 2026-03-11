import Foundation

enum TextCleanupService {
    private static let fillerRegexes: [NSRegularExpression] = {
        let patterns = [
            "\\bum\\b,?\\s*", "\\buh\\b,?\\s*",
            // Only match "like" as a filler: preceded by comma/start or followed by comma
            // Avoids stripping "I like pizza" while catching "I was, like, going"
            "(?<=, )like,?\\s*",
            ",\\s*like\\b,?\\s*",
            "\\byou know\\b,?\\s*", "\\bbasically\\b,?\\s*",
            "\\bactually\\b,?\\s*", "\\bsort of\\b,?\\s*",
            "\\bkind of\\b,?\\s*", "\\bi mean\\b,?\\s*",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    /// Apply all cleanup steps to transcribed text.
    static func clean(_ text: String) -> String {
        var result = text

        // Remove filler words (case-insensitive)
        for regex in fillerRegexes {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Fix double/triple spaces (single-pass regex)
        result = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)

        // Auto-capitalize first letter of sentences
        result = capitalizeSentences(result)

        // Trim trailing whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    private static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = Array(text)
        var capitalizeNext = true

        for i in result.indices {
            if capitalizeNext && result[i].isLetter {
                result[i] = Character(result[i].uppercased())
                capitalizeNext = false
            } else if result[i] == "." || result[i] == "!" || result[i] == "?" {
                capitalizeNext = true
            }
        }

        return String(result)
    }
}
