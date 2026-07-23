import Foundation
import Testing
@testable import Speaky

@Suite("AppSettings", .serialized)
struct AppSettingsTests {

    @Test("Show in Dock is disabled by default")
    func showInDockDefault() {
        withRestoredShowInDockPreference {
            UserDefaults.standard.removeObject(forKey: AppSettings.showInDockDefaultsKey)

            #expect(AppSettings().showInDock == false)
        }
    }

    @Test("Show in Dock is persisted")
    func showInDockPersistence() {
        withRestoredShowInDockPreference {
            let settings = AppSettings()

            settings.showInDock = true

            #expect(AppSettings().showInDock)
        }
    }

    private func withRestoredShowInDockPreference(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let savedValue = defaults.object(forKey: AppSettings.showInDockDefaultsKey)
        defer {
            if let savedValue {
                defaults.set(savedValue, forKey: AppSettings.showInDockDefaultsKey)
            } else {
                defaults.removeObject(forKey: AppSettings.showInDockDefaultsKey)
            }
        }

        body()
    }
}
