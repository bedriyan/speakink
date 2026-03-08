import Foundation
@preconcurrency import KeyboardShortcuts
import Carbon
import AppKit
import os

extension KeyboardShortcuts.Name {
    nonisolated(unsafe) static let toggleRecording = Self("toggleRecording", default: .init(.space, modifiers: .option))
}

@Observable
@MainActor
final class HotkeyManager: @unchecked Sendable {
    private let logger = Logger.speaky(category: "HotkeyManager")

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

    // NSEvent monitors
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var localEscapeMonitor: Any?

    // CGEvent tap for global ESC (more reliable than NSEvent global monitor)
    private var escapeTapPort: CFMachPort?
    private var escapeTapSource: CFRunLoopSource?

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

    // Fn key debounce
    private var fnDebounceTask: Task<Void, Never>?
    private var pendingFnKeyState: Bool?
    private var pendingFnEventTime: TimeInterval?

    // State exposed to UI
    private(set) var isRecordingViaHotkey = false

    init() {
        // Always use custom shortcut mode (modifier presets removed)
        self.selectedHotkey = .custom
        UserDefaults.standard.set(HotkeyOption.custom.rawValue, forKey: "selectedHotkey")

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
        // CGEvent tap captures ESC globally even when other apps consume the key event.
        // NSEvent.addGlobalMonitorForEvents is only an observer and misses consumed events.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // Re-enable tap if it gets disabled by the system
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown,
                  event.getIntegerValueField(.keyboardEventKeycode) == Int64(Constants.KeyCode.escape),
                  let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                manager.onEscapePressed?()
            }

            // Pass event through (don't consume it)
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: selfPtr
        ) {
            escapeTapPort = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            escapeTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            logger.info("CGEvent tap for ESC installed successfully")
        } else {
            logger.warning("Failed to create CGEvent tap for ESC — falling back to NSEvent monitor")
            // Fallback: NSEvent global monitor (less reliable but better than nothing)
            let fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == Constants.KeyCode.escape else { return }
                Task { @MainActor in
                    self?.onEscapePressed?()
                }
            }
            globalEventMonitor = globalEventMonitor ?? fallbackMonitor
        }

        // Local monitor for when Speaky itself is focused
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Constants.KeyCode.escape else { return event }
            Task { @MainActor in
                self?.onEscapePressed?()
            }
            return event
        }
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

    private func handleCustomShortcutKeyDown(eventTime: TimeInterval) async {
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

    private func handleCustomShortcutKeyUp(eventTime: TimeInterval) async {
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
    }

    var isShortcutConfigured: Bool {
        if selectedHotkey == .custom {
            return KeyboardShortcuts.getShortcut(for: .toggleRecording) != nil
        }
        return true
    }

    deinit {
        // Release system resources that would otherwise leak.
        // These Core Foundation and NSEvent calls are safe from any thread at teardown.
        if let monitor = globalEventMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor) }
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
