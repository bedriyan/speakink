import AppKit
import Testing
@testable import Speaky

@Suite("Dock visibility policy")
struct DockVisibilityPolicyTests {

    @Test("hides from Dock when disabled and no window is open")
    func hiddenWithoutWindow() {
        let policy = DockVisibilityPolicy.activationPolicy(
            showInDock: false,
            hasOpenWindow: false
        )

        #expect(policy == .accessory)
    }

    @Test("shows in Dock while a window is open")
    func shownWithOpenWindow() {
        let policy = DockVisibilityPolicy.activationPolicy(
            showInDock: false,
            hasOpenWindow: true
        )

        #expect(policy == .regular)
    }

    @Test("stays in Dock when enabled")
    func shownWhenEnabled() {
        let policy = DockVisibilityPolicy.activationPolicy(
            showInDock: true,
            hasOpenWindow: false
        )

        #expect(policy == .regular)
    }
}
