import AppKit
import ApplicationServices

/// Read-only view of the Apple Dock through Accessibility: its icon list, what each icon
/// points at, badges and on-screen frames. The Dock exposes one AXList of AXDockItems.
enum DockAX {
    static let bundleID = "com.apple.dock"
    static let statusLabelAttribute = "AXStatusLabel"
    static let appItemSubrole = "AXApplicationDockItem"
    static let separatorSubrole = "AXSeparatorDockItem"
    static let folderSubrole = "AXFolderDockItem"
    static let runningAttribute = "AXIsApplicationRunning"

    struct Item {
        /// nil for items only on win-tab's own Dock.
        let element: AXUIElement?
        let title: String
        let subrole: String
        let url: URL?
        let badge: String?
        /// Global, top-left origin (CG/AX coordinates).
        let frame: CGRect?
        /// The app is running (the Dock's own dot). Read with the item, so callers on the main
        /// thread don't ask LaunchServices per item.
        var isRunning = false

        var isApp: Bool { subrole == DockAX.appItemSubrole }

        /// An item that isn't on Apple's Dock (win-tab's own arrangement).
        static func local(title: String, url: URL?, subrole: String) -> Item {
            Item(element: nil, title: title, subrole: subrole, url: url, badge: nil, frame: nil)
        }

        func isSame(as other: Item) -> Bool {
            if let a = element, let b = other.element { return CFEqual(a, b) }
            return url == other.url && title == other.title
        }
        var bundleID: String? { url.flatMap { Bundle(url: $0)?.bundleIdentifier } }
        var runningApp: NSRunningApplication? {
            guard isApp, let bid = bundleID else { return nil }
            return NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
        }
    }

    static var dockPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    /// A busy Dock must not stall callers for AX's multi-second default.
    private static let messagingTimeout: Float = 0.2

    static func list(dockPID pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let list = children(of: app).first { string(kAXRoleAttribute, of: $0) == kAXListRole }
        if let list { AXUIElementSetMessagingTimeout(list, messagingTimeout) }
        return list
    }

    static func items() -> [Item] {
        guard let pid = dockPID, let list = list(dockPID: pid) else { return [] }
        return children(of: list).map(item(for:))
    }

    static func item(for element: AXUIElement) -> Item {
        var urlRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef)
        var item = Item(
            element: element,
            title: string(kAXTitleAttribute, of: element) ?? "",
            subrole: string(kAXSubroleAttribute, of: element) ?? "",
            url: urlRef as? URL,
            badge: string(statusLabelAttribute, of: element),
            frame: AXHelpers.frame(of: element)
        )
        if item.isApp {
            var running: CFTypeRef?
            item.isRunning = AXUIElementCopyAttributeValue(element, runningAttribute as CFString, &running) == .success
                ? (running as? Bool ?? false)
                : item.runningApp != nil
        }
        return item
    }

    /// The icon under the pointer: the Dock marks the hovered item as its list's selection.
    static func hoveredItem(in list: AXUIElement) -> Item? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXSelectedChildrenAttribute as CFString, &ref) == .success,
              let selected = (ref as? [AXUIElement])?.first else { return nil }
        return item(for: selected)
    }

    /// Bundle ID → badge text for every running app the Dock shows a badge on.
    static func badges() -> [String: String] {
        var out: [String: String] = [:]
        for item in items() where item.isApp {
            guard let badge = item.badge, !badge.isEmpty, let bid = item.bundleID else { continue }
            out[bid] = badge
        }
        return out
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
