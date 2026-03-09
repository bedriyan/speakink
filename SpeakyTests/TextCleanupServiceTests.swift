import Testing
@testable import Speaky

@Suite("TextCleanupService")
struct TextCleanupServiceTests {

    @Test("removes common filler words")
    func removeFillerWords() {
        let input = "So um I think uh we should basically do this"
        let result = TextCleanupService.clean(input)
        #expect(!result.contains("um"))
        #expect(!result.contains("uh"))
        #expect(!result.contains("basically"))
    }

    @Test("removes filler words case-insensitively")
    func caseInsensitiveFillers() {
        let input = "Um I think UH we should"
        let result = TextCleanupService.clean(input)
        #expect(!result.lowercased().contains("um "))
        #expect(!result.lowercased().contains("uh "))
    }

    @Test("collapses multiple spaces into one")
    func collapseSpaces() {
        let input = "Hello   world  test"
        let result = TextCleanupService.clean(input)
        #expect(!result.contains("  "))
    }

    @Test("capitalizes first letter of sentences")
    func capitalizeSentences() {
        let input = "hello world. this is a test. another sentence!"
        let result = TextCleanupService.clean(input)
        #expect(result.hasPrefix("Hello"))
        #expect(result.contains("This is"))
        #expect(result.contains("Another sentence"))
    }

    @Test("trims leading and trailing whitespace")
    func trimWhitespace() {
        let input = "  hello world  "
        let result = TextCleanupService.clean(input)
        #expect(result == "Hello world")
    }

    @Test("handles empty string")
    func emptyString() {
        let result = TextCleanupService.clean("")
        #expect(result.isEmpty)
    }

    @Test("handles string with only filler words")
    func onlyFillers() {
        let input = "um uh"
        let result = TextCleanupService.clean(input)
        #expect(result.isEmpty)
    }

    @Test("preserves legitimate uses of filler-like words within larger words")
    func preservesSubstrings() {
        // "like" as a standalone filler vs. part of a word
        let input = "I likelihood of success"
        let result = TextCleanupService.clean(input)
        #expect(result.contains("likelihood"))
    }

    @Test("handles punctuation after filler removal")
    func punctuationAfterFiller() {
        let input = "hello. um goodbye."
        let result = TextCleanupService.clean(input)
        #expect(result.contains("Goodbye"))
    }
}
