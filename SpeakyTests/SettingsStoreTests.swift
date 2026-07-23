import Testing
@testable import Speaky

@Suite("App settings persistence")
struct SettingsStoreTests {
    @Test("Persists through the injected store")
    func persistsThroughInjectedStore() {
        let store = InMemorySettingsStore()
        let first = AppSettings(store: store)
        first.backgroundAudioMode = .off
        first.selectedAudioDevice = 42
        first.soundEffectsEnabled = false

        let second = AppSettings(store: store)

        #expect(second.backgroundAudioMode == .off)
        #expect(second.selectedAudioDevice == 42)
        #expect(!second.soundEffectsEnabled)
    }

    @Test("Separate stores do not share preferences")
    func separateStoresAreIsolated() {
        let first = AppSettings(store: InMemorySettingsStore())
        first.backgroundAudioMode = .off

        let second = AppSettings(store: InMemorySettingsStore())

        #expect(second.backgroundAudioMode == .pauseMedia)
    }
}
