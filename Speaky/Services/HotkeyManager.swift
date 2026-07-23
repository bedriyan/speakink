import Foundation
@preconcurrency import KeyboardShortcuts
import Carbon
import AppKit
import os

private func escapeEventTapCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in
            manager.restoreEscapeTapIfNeeded()
        }
        return Unmanaged.passUnretained(event)
    }

    guard HotkeyManager.shouldInterceptEscape(
        eventType: type,
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        isEnabled: true
    ) else {
        return Unmanaged.passUnretained(event)
    }

    Task { @MainActor in
        manager.handleMonitoredEscape()
    }

    // While recording, ESC belongs exclusively to Speaky.
    return nil
}

extension KeyboardShortcuts.Name {
    nonisolated(unsafe) static let toggleRecording = Self("toggleRecording", default: .init(.space, modifiers: .option))
}

@Observable
@MainActor
final class HotkeyManager: @unchecked Sendable {
    private let logger = Logger.speaky(category: "HotkeyManager")
    private let usesSystemMonitoring: Bool

    enum HotkeyOption: String, CaseIterable, Identifiable {
        case rightOption = "rightOption"
        case leftOption = "leftOption"
        case rightCommand = "rightCommand"
        case rightControl = "rightControl"
        case fn = "fn"
        case custom = "custom"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .rightOption: "Right Option (⌥)"
            case .leftOption: "Left Option (⌥)"
            case .rightCommand: "Right Command (⌘)"
            case .rightControl: "Right Control (⌃)"
            case .fn: "Fn"
            case .custom: "Custom Shortcut"
            }
        }

        var keyCode: CGKeyCode? {
            switch self {
            case .rightOption: 0x3D
            case .leftOption: 0x3A
            case .rightCommand: 0x36
            case .rightControl: 0x3E
            case .fn: 0x3F
            case .custom: nil
            }
        }

        var isModifierKey: Bool { self != .custom }
    }

    // Configuration
    var selectedHotkey: HotkeyOption {
        didSet {
            UserDefaults.standard.set(selectedHotkey.rawValue, forKey: "selectedHotkey")
            setupMonitoring()
        }
    }

    // Callbacks
    var onToggleRecording: (() -> Void)?
    var onEscapePressed: (() -> Void)?
    var onEscapeMonitoringAvailabilityChanged: ((Bool) -> Void)?

    // NSEvent monitors — nonisolated(unsafe) so deinit can clean them up
    private nonisolated(unsafe) var globalEventMonitor: Any?
    private nonisolated(unsafe) var localEventMonitor: Any?
    private nonisolated(unsafe) var globalEscapeMonitor: Any?
    private nonisolated(unsafe) var localEscapeMonitor: Any?

    // Active only while recording so ESC remains untouched at all other times.
    private nonisolated(unsafe) var escapeTapPort: CFMachPort?
    private nonisolated(unsafe) var escapeTapSource: CFRunLoopSource?
    private(set) var isEscapeCancellationEnabled = false

    // Push-to-talk / hands-free state
    private var currentKeyState = false
    private var keyPressEventTime: TimeInterval?
    private let briefPressThreshold: TimeInterval = Constants.Timing.hotkeyBriefPressThreshold
    private var isHandsFreeMode = false

    // Custom shortcut state
    private var shortcutKeyPressEventTime: TimeInterval?
    private var isShortcutHandsFreeMode = false
    private var shortcutCurrentKeyState = false
    private var lastShortcutTriggerTime: Date?
    private let shortcutCooldownInterval: TimeInterval = 0.3
    private var suppressModifierUntilRelease = false
    private var suppressShortcutUntilRelease = false

    // Fn key debounce — nonisolated(unsafe) so deinit can cancel it
    private nonisolated(unsafe) var fnDebounceTask: Task<Void, Never>?
    private var pendingFnKeyState: Bool?
    private var pendingFnEventTime: TimeInterval?

    // State exposed to UI
    private(set) var isRecordingViaHotkey = false

    init(startMonitoring: Bool = true) {
        self.usesSystemMonitoring = startMonitoring

        // Always use custom shortcut mode (modifier presets removed)
        self.selectedHotkey = .custom
        UserDefaults.standard.set(HotkeyOption.custom.rawValue, forKey: "selectedHotkey")

        guard startMonitoring else { return }

        // Slight delay to ensure app is fully launched
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.setupMonitoring()
        }
    }

    // MARK: - Setup

    private func setupMonitoring() {
        removeAllMonitoring()

        if selectedHotkey.isModifierKey {
            setupModifierKeyMonitoring()
        } else {
            setupCustomShortcutMonitoring()
        }
        setupEscapeMonitoring()
        logger.info("Hotkey monitoring set up for: \(self.selectedHotkey.displayName)")
    }

    private func setupEscapeMonitoring() {
        installEscapeTapIfAvailable()

        if isEscapeCancellationEnabled && escapeTapPort == nil {
            installGlobalEscapeFallback()
        }

        // Local monitor for when Speaky itself is focused
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  Self.shouldInterceptEscape(
                    eventType: .keyDown,
                    keyCode: Int64(event.keyCode),
                    isEnabled: self.isEscapeCancellationEnabled
                  ) else { return event }
            self.handleMonitoredEscape()
            return nil
        }
    }

    private func installEscapeTapIfAvailable() {
        guard escapeTapPort == nil else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: escapeEventTapCallback,
            userInfo: selfPtr
        ) {
            escapeTapPort = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            escapeTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: isEscapeCancellationEnabled)
            logger.info("Active session event tap for ESC installed successfully")
            onEscapeMonitoringAvailabilityChanged?(true)
        } else {
            logger.warning("Failed to create active ESC event tap — will retry when recording starts")
        }
    }

    private func installGlobalEscapeFallback() {
        guard globalEscapeMonitor == nil else { return }
        logger.warning("Using passive ESC monitor because the active event tap is unavailable")
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Constants.KeyCode.escape else { return }
            Task { @MainActor in
                self?.handleMonitoredEscape()
            }
        }
        onEscapeMonitoringAvailabilityChanged?(false)
    }

    nonisolated static func shouldInterceptEscape(
        eventType: CGEventType,
        keyCode: Int64,
        isEnabled: Bool
    ) -> Bool {
        isEnabled
            && eventType == .keyDown
            && keyCode == Int64(Constants.KeyCode.escape)
    }

    func setEscapeCancellationEnabled(_ enabled: Bool) {
        guard isEscapeCancellationEnabled != enabled else { return }
        isEscapeCancellationEnabled = enabled

        if enabled && escapeTapPort == nil && usesSystemMonitoring {
            // Accessibility may have been granted since launch.
            installEscapeTapIfAvailable()
        }

        if let tap = escapeTapPort {
            CGEvent.tapEnable(tap: tap, enable: enabled)
        } else if enabled && usesSystemMonitoring {
            installGlobalEscapeFallback()
        }

        if !enabled, let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscapeMonitor = nil
        }
    }

    func handleMonitoredEscape() {
        guard isEscapeCancellationEnabled else { return }
        setEscapeCancellationEnabled(false)
        cancelActiveHotkeyInteraction()
        onEscapePressed?()
    }

    private func cancelActiveHotkeyInteraction() {
        suppressModifierUntilRelease = currentKeyState || pendingFnKeyState == true
        suppressShortcutUntilRelease = shortcutCurrentKeyState
        fnDebounceTask?.cancel()
        fnDebounceTask = nil
        pendingFnKeyState = nil
        pendingFnEventTime = nil
        currentKeyState = false
        keyPressEventTime = nil
        isHandsFreeMode = false
        shortcutCurrentKeyState = false
        shortcutKeyPressEventTime = nil
        isShortcutHandsFreeMode = false
    }

    fileprivate func restoreEscapeTapIfNeeded() {
        guard isEscapeCancellationEnabled, let tap = escapeTapPort else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func setupModifierKeyMonitoring() {
        let targetKeyCode = selectedHotkey.keyCode
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, event.keyCode == targetKeyCode else { return }
            Task { @MainActor in
                await self.handleModifierKeyEvent(event)
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, event.keyCode == targetKeyCode else { return event }
            Task { @MainActor in
                await self.handleModifierKeyEvent(event)
            }
            return event
        }
    }

    private func setupCustomShortcutMonitoring() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            let eventTime = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                await self?.handleCustomShortcutKeyDown(eventTime: eventTime)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            let eventTime = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                await self?.handleCustomShortcutKeyUp(eventTime: eventTime)
            }
        }
    }

    // MARK: - Modifier key handling

    private func handleModifierKeyEvent(_ event: NSEvent) async {
        let keycode = event.keyCode
        let flags = event.modifierFlags
        let eventTime = event.timestamp

        guard selectedHotkey.keyCode == keycode else { return }

        var isKeyPressed = false

        switch selectedHotkey {
        case .rightOption, .leftOption:
            isKeyPressed = flags.contains(.option)
        case .rightControl:
            isKeyPressed = flags.contains(.control)
        case .rightCommand:
            isKeyPressed = flags.contains(.command)
        case .fn:
            isKeyPressed = flags.contains(.function)
            // Debounce Fn key (it fires spuriously on some Macs)
            pendingFnKeyState = isKeyPressed
            pendingFnEventTime = eventTime
            fnDebounceTask?.cancel()
            fnDebounceTask = Task { [pendingState = isKeyPressed, pendingTime = eventTime] in
                try? await Task.sleep(nanoseconds: 75_000_000) // 75ms
                guard !Task.isCancelled else { return }
                if self.pendingFnKeyState == pendingState {
                    await self.processKeyPress(isKeyPressed: pendingState, eventTime: pendingTime)
                }
            }
            return
        case .custom:
            return
        }

        await processKeyPress(isKeyPressed: isKeyPressed, eventTime: eventTime)
    }

    /// Push-to-talk + hands-free logic:
    /// - Short press (<0.4s): enters hands-free mode (tap to start, tap to stop)
    /// - Long press (≥0.4s): push-to-talk (hold to record, release to stop)
    private func processKeyPress(isKeyPressed: Bool, eventTime: TimeInterval) async {
        if suppressModifierUntilRelease {
            if !isKeyPressed {
                suppressModifierUntilRelease = false
            }
            return
        }

        guard isKeyPressed != currentKeyState else { return }
        currentKeyState = isKeyPressed

        if isKeyPressed {
            keyPressEventTime = eventTime

            if isHandsFreeMode {
                // Second tap in hands-free mode → stop recording
                isHandsFreeMode = false
                triggerToggle()
                return
            }

            // Key down → start recording
            triggerToggle()
        } else {
            // Key up
            if let startTime = keyPressEventTime {
                let pressDuration = eventTime - startTime
                if pressDuration < briefPressThreshold {
                    // Brief press → hands-free mode (stay recording until next tap)
                    isHandsFreeMode = true
                } else {
                    // Long press release → stop recording (push-to-talk)
                    triggerToggle()
                }
            }
            keyPressEventTime = nil
        }
    }

    // MARK: - Custom shortcut handling

    func handleCustomShortcutKeyDown(eventTime: TimeInterval) async {
        guard !suppressShortcutUntilRelease else { return }

        // Cooldown to prevent double-triggers
        if let lastTrigger = lastShortcutTriggerTime,
           Date().timeIntervalSince(lastTrigger) < shortcutCooldownInterval {
            return
        }

        guard !shortcutCurrentKeyState else { return }
        shortcutCurrentKeyState = true
        lastShortcutTriggerTime = Date()
        shortcutKeyPressEventTime = eventTime

        if isShortcutHandsFreeMode {
            isShortcutHandsFreeMode = false
            triggerToggle()
            return
        }

        triggerToggle()
    }

    func handleCustomShortcutKeyUp(eventTime: TimeInterval) async {
        if suppressShortcutUntilRelease {
            suppressShortcutUntilRelease = false
            return
        }

        guard shortcutCurrentKeyState else { return }
        shortcutCurrentKeyState = false

        if let startTime = shortcutKeyPressEventTime {
            let pressDuration = eventTime - startTime
            if pressDuration < briefPressThreshold {
                isShortcutHandsFreeMode = true
            } else {
                triggerToggle()
            }
        }
        shortcutKeyPressEventTime = nil
    }

    // MARK: - Trigger

    private func triggerToggle() {
        logger.notice("Hotkey triggered toggle recording")
        onToggleRecording?()
    }

    // MARK: - Cleanup

    private func removeAllMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscapeMonitor = nil
        }
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            localEscapeMonitor = nil
        }
        // Clean up CGEvent tap
        if let source = escapeTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            escapeTapSource = nil
        }
        if let port = escapeTapPort {
            CGEvent.tapEnable(tap: port, enable: false)
            escapeTapPort = nil
        }
        fnDebounceTask?.cancel()
        KeyboardShortcuts.removeAllHandlers()
        resetKeyStates()
    }

    private func resetKeyStates() {
        currentKeyState = false
        keyPressEventTime = nil
        isHandsFreeMode = false
        shortcutCurrentKeyState = false
        shortcutKeyPressEventTime = nil
        isShortcutHandsFreeMode = false
        suppressModifierUntilRelease = false
        suppressShortcutUntilRelease = false
    }

    var isShortcutConfigured: Bool {
        if selectedHotkey == .custom {
            return KeyboardShortcuts.getShortcut(for: .toggleRecording) != nil
        }
        return true
    }

    deinit {
        // Release system resources that would otherwise leak.
        if let monitor = globalEventMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalEscapeMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localEscapeMonitor { NSEvent.removeMonitor(monitor) }
        if let source = escapeTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port = escapeTapPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        fnDebounceTask?.cancel()
        KeyboardShortcuts.removeAllHandlers()
    }
}
