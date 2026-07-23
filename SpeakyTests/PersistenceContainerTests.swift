import Testing
@testable import Speaky

@Suite("Persistence container")
struct PersistenceContainerTests {
    @Test("Hosted tests are detected")
    func hostedTestsAreDetected() {
        #expect(PersistenceContainer.isRunningTests)
    }

    @Test("In-memory container initializes")
    func inMemoryContainerInitializes() throws {
        _ = try PersistenceContainer.make(isStoredInMemoryOnly: true)
    }
}
