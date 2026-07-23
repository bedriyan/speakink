import AppKit

enum DockVisibilityPolicy {
    static func activationPolicy(
        showInDock: Bool,
        hasOpenWindow: Bool
    ) -> NSApplication.ActivationPolicy {
        showInDock || hasOpenWindow ? .regular : .accessory
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var appState: AppState? {
        didSet {
            updateActivationPolicy()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let notificationCenter = NotificationCenter.default
        for name in [
            NSWindow.didBecomeMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ] {
            notificationCenter.addObserver(
                self,
                selector: #selector(windowVisibilityDidChange),
                name: name,
                object: nil
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.updateActivationPolicy()
            NSApp.activate(ignoringOtherApps: true)
        }

        // Accessibility and microphone prompts are user-triggered only —
        // via onboarding "Grant" buttons or the Settings Permissions section.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        let hasVisibleUserFacingWindow = NSApp.windows.contains {
            isUserFacing($0) && ($0.isVisible || $0.isMiniaturized)
        }

        if !hasVisibleUserFacingWindow {
            NSApp.setActivationPolicy(.regular)
            for window in NSApp.windows where isUserFacing(window) {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy()
        }
    }

    private func updateActivationPolicy() {
        let showInDock = appState?.settings.showInDock
            ?? (UserDefaults.standard.object(forKey: AppSettings.showInDockDefaultsKey) as? Bool ?? false)
        let hasOpenWindow = NSApp.windows.contains {
            isUserFacing($0) && ($0.isVisible || $0.isMiniaturized)
        }
        let policy = DockVisibilityPolicy.activationPolicy(
            showInDock: showInDock,
            hasOpenWindow: hasOpenWindow
        )

        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    private func isUserFacing(_ window: NSWindow) -> Bool {
        window.canBecomeMain && window.styleMask.contains(.titled)
    }
}
