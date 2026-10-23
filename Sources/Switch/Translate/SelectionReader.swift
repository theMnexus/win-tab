import AppKit
import ApplicationServices

/// The text selected in the front app for ⌃⌥C: read over Accessibility when the app exposes it,
/// otherwise copied with a synthetic ⌘C (the clipboard is put back as it was and the copy is
/// kept out of the Clipboard history). With nothing selected, the clipboard's own text.
@MainActor
enum SelectionReader {
    private static let copyWait: TimeInterval = 0.35
    private static let copyPoll: TimeInterval = 0.05
    private static let maxLength = 5_000

    static func read(_ done: @escaping @MainActor (String?) -> Void) {
        if let text = accessibilitySelection() {
            done(trimmed(text))
            return
        }
        copySelection { copied in
            done(trimmed(copied ?? NSPasteboard.general.string(forType: .string) ?? ""))
        }
    }

    private static func trimmed(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > maxLength ? String(t.prefix(maxLength)) : t
    }

    private static func accessibilitySelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        // A hung app must not stall the hotkey.
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// ⌘C into the front app, then whatever it put on the pasteboard; nil if nothing changed.
    private static func copySelection(_ done: @escaping @MainActor (String?) -> Void) {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [:]) { dict, type in dict[type] = item.data(forType: type) }
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: down) // C
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        let deadline = Date().addingTimeInterval(copyWait)
        func check() {
            if pb.changeCount != before {
                let text = pb.string(forType: .string)
                restore(saved)
                done(text)
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + copyPoll) { MainActor.assumeIsolated { check() } }
            } else {
                done(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + copyPoll) { MainActor.assumeIsolated { check() } }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        ClipboardHistory.shared.ignoreCurrentChange()
    }
}
