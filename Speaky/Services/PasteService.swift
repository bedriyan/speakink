import AppKit
import Carbon.HIToolbox
import os

private let logger = Logger.speaky(category: "PasteService")

final class PasteService: @unchecked Sendable {

    /// Paste text at the current cursor position using Cmd+V simulation.
    func paste(_ text: String) {
        guard !text.isEmpty else {
            logger.warning("Paste skipped — empty text")
            return
        }
        logger.info("Paste called — text length: \(text.count) characters")

        // Always copy to clipboard first
        let pasteboard = NSPasteboard.general
        let savedItems = savePasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Check accessibility - if not trusted, just leave text on clipboard
        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility not trusted — text copied to clipboard only. Please grant Accessibility in System Settings.")
            return
        }

        // Delay to ensure pasteboard is ready, then simulate Cmd+V on a background queue
        // to avoid blocking the main thread with usleep calls
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Constants.Timing.pasteboardReadyDelay) { [weak self] in
            self?.simulateCmdV()

            // Restore previous clipboard after paste completes
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.pasteboardRestoreDelay) { [weak self] in
                self?.restorePasteboard(pasteboard, items: savedItems)
            }
        }
    }

    /// Simulate Cmd+V keystroke using CGEvent (VoiceInk approach)
    private func simulateCmdV() {
        let source = CGEventSource(stateID: .privateState)

        // Virtual key codes: 0x37 = Command, 0x09 = V
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            logger.error("Failed to create CGEvents")
            return
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        usleep(20_000)
        vDown.post(tap: .cghidEventTap)
        usleep(20_000)
        vUp.post(tap: .cghidEventTap)
        usleep(20_000)
        cmdUp.post(tap: .cghidEventTap)

        logger.notice("Cmd+V posted via CGEvent")
    }

    // MARK: - Clipboard save/restore

    private func savePasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict.isEmpty ? nil : dict
        } ?? []
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        for itemDict in items {
            let item = NSPasteboardItem()
            for (type, data) in itemDict {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }

    // MARK: - Accessibility

    static func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
