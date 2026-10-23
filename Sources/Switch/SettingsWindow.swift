import AppKit
import SwiftUI

/// Settings window host. Close demotes the app back to .accessory.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var demoteWork: DispatchWorkItem?

    var isVisible: Bool { window?.isVisible == true }

    private init() {}

    /// Opens Settings on a tab ("battery", "notch"…).
    func show(tab: String) {
        // A window made just now picks it up on appear; an open one hears the notification.
        pendingTab = tab
        show()
        NotificationCenter.default.post(name: Self.selectTab, object: tab)
    }

    /// Tab for a Settings window that hasn't appeared yet.
    var pendingTab: String?

    static let selectTab = Notification.Name("switch.settings.selectTab")

    func show() {
        demoteWork?.cancel()
        demoteWork = nil
        // Stays .accessory: an inactive .regular app's activate() calls are ignored, breaking switching.

        if let existing = window {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        let host = NSHostingController(rootView: SettingsView())
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "win-tab Settings"
        win.contentViewController = host
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = SettingsWindowDelegate.shared

        window = win
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    func handleClose() {
        window = nil
        demoteWork?.cancel()
        let work = DispatchWorkItem {
            NSApp.setActivationPolicy(.accessory)
        }
        demoteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            SettingsWindow.shared.handleClose()
        }
    }
}
