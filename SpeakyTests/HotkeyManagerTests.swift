import CoreGraphics
import Testing
@testable import Speaky

@Suite("HotkeyManager")
@MainActor
struct HotkeyManagerTests {
    @Test("ESC key-down is intercepted only while cancellation is enabled")
    func escapeKeyDownRequiresActiveRecording() {
        #expect(HotkeyManager.shouldInterceptEscape(
            eventType: .keyDown,
            keyCode: Int64(Constants.KeyCode.escape),
            isEnabled: true
        ))
        #expect(!HotkeyManager.shouldInterceptEscape(
            eventType: .keyDown,
            keyCode: Int64(Constants.KeyCode.escape),
            isEnabled: false
        ))
    }

    @Test("Other key events are never intercepted")
    func otherKeyEventsPassThrough() {
        #expect(!HotkeyManager.shouldInterceptEscape(
            eventType: .keyUp,
            keyCode: Int64(Constants.KeyCode.escape),
            isEnabled: true
        ))
        #expect(!HotkeyManager.shouldInterceptEscape(
            eventType: .keyDown,
            keyCode: Int64(Constants.KeyCode.escape + 1),
            isEnabled: true
        ))
    }

    @Test("Escape cancels once and suppresses a held shortcut release")
    func escapeSuppressesHeldShortcutRelease() async {
        let manager = HotkeyManager(startMonitoring: false)
        var toggleCount = 0
        var escapeCount = 0
        manager.onToggleRecording = { toggleCount += 1 }
        manager.onEscapePressed = { escapeCount += 1 }

        await manager.handleCustomShortcutKeyDown(eventTime: 0)
        #expect(toggleCount == 1)

        manager.setEscapeCancellationEnabled(true)
        manager.handleMonitoredEscape()
        manager.handleMonitoredEscape()
        await manager.handleCustomShortcutKeyUp(eventTime: 1)

        #expect(escapeCount == 1)
        #expect(toggleCount == 1)
        #expect(!manager.isEscapeCancellationEnabled)
    }
}
