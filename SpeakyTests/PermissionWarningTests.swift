import Testing
@testable import Speaky

@Suite("Permission warnings")
struct PermissionWarningTests {
    @Test(
        "Warning reflects current permission state",
        arguments: [
            (true, false, false, "Microphone and Accessibility permissions are missing. Go to Settings > Permissions to fix this."),
            (true, true, false, "Microphone access was revoked. Go to Settings > Permissions to restore it."),
            (false, false, false, "Accessibility access is missing — auto-paste and global Escape cancellation won't work. Go to Settings > Permissions to enable it."),
            (false, true, false, "Global Escape cancellation is unavailable. Re-enable Accessibility for Speaky in Settings > Permissions, then try again."),
            (false, true, true, nil)
        ]
    )
    func currentPermissionState(
        microphoneDenied: Bool,
        accessibilityGranted: Bool,
        escapeMonitoringAvailable: Bool,
        expectedWarning: String?
    ) {
        #expect(AppState.permissionWarningMessage(
            microphoneDenied: microphoneDenied,
            accessibilityGranted: accessibilityGranted,
            escapeMonitoringAvailable: escapeMonitoringAvailable
        ) == expectedWarning)
    }
}
