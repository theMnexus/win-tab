import AppKit
import SwiftUI

@MainActor
final class AboutWindow {
    static let shared = AboutWindow()
    private var window: NSWindow?
    private init() {}

    func show() {
        // Stays .accessory, same reason as SettingsWindow.
        if let existing = window {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }
        let host = NSHostingController(rootView: AboutView())
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About win-tab"
        win.contentMinSize = NSSize(width: 380, height: 360)
        win.contentViewController = host
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.delegate = AboutWindowDelegate.shared
        window = win
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    func handleClose() {
        window = nil
        if !SettingsWindow.shared.isVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

private final class AboutWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = AboutWindowDelegate()
    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in AboutWindow.shared.handleClose() }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if let win = notification.object as? NSWindow { win.level = .floating }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            }
            VStack(spacing: 4) {
                Text("win-tab")
                    .font(.system(size: 22, weight: .semibold))
                Text("Version \(BuildInfo.versionLine)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let stamp = BuildInfo.stamp {
                    Text(stamp)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Text("Keyboard-driven window switcher for macOS.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text("win-tab by MN")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                // Original notice, kept as the FSL license requires.
                Text("Based on Switch © 2026 Sanyam Garg")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)
        }
        .frame(width: 380, height: 340)
        .padding(.vertical, 8)
    }
}

enum BuildInfo {
    static var versionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
    static var stamp: String? {
        let info = Bundle.main.infoDictionary
        guard let commit = info?["BuildCommit"] as? String,
              let date = info?["BuildDate"] as? String,
              !commit.isEmpty else { return nil }
        return "\(commit) · \(date)"
    }
}
