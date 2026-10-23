import AppKit
import SwiftUI

/// Each app's alert style as macOS has it (System Settings → Notifications), read from its own
/// preferences. Only read: macOS doesn't let another app change these, so the setup list links
/// to each app's page instead.
enum NotificationStyles {
    enum Style: Equatable {
        case none, banners, alerts, off

        /// Notifications still reach the list win-tab reads, without a banner.
        var notchOnly: Bool { self == .none }
    }

    /// `flags` keeps the alert style in bits 3–4 (0 none, 1 banners, 2 alerts) and "Allow
    /// notifications" in bit 25.
    static func style(flags: Int) -> Style {
        guard flags & (1 << 25) != 0 else { return .off }
        switch (flags >> 3) & 0b11 {
        case 1: return .banners
        case 2: return .alerts
        default: return .none
        }
    }

    /// Bundle id (lowercased) → style, for every app macOS keeps notification settings for.
    static func read() -> [String: Style] {
        guard let apps = CFPreferencesCopyAppValue("apps" as CFString, "com.apple.ncprefs" as CFString) as? [[String: Any]] else { return [:] }
        var out: [String: Style] = [:]
        for app in apps {
            guard let id = app["bundle-id"] as? String, let flags = (app["flags"] as? NSNumber)?.intValue else { continue }
            out[id.lowercased()] = style(flags: flags)
        }
        return out
    }

    /// System Settings → Notifications, on this app's page.
    static func openSettings(for bundleID: String?) {
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let url = URL(string: bundleID.map { "\(base)?id=\($0)" } ?? base) ?? URL(string: base) { NSWorkspace.shared.open(url) }
    }

    #if DEBUG
    static func selfCheck() -> [String] {
        var failures: [String] = []
        // Values from a real Mac: Telegram on banners, Zalo on None, Script Editor not allowed.
        if style(flags: 310_386_762) != .banners { failures.append("notification styles: banners") }
        if style(flags: 41_951_302) != .none { failures.append("notification styles: none") }
        if style(flags: 8_396_814) != .off { failures.append("notification styles: not allowed") }
        if style(flags: 16 | (1 << 25)) != .alerts { failures.append("notification styles: alerts") }
        return failures
    }
    #endif
}

/// Settings → Notch → Notifications → Only on the notch: turn off each app's macOS banners while
/// its notifications keep coming to the notch.
struct NotificationSetupList: View {
    @ObservedObject private var feed = NotificationFeed.shared
    @State private var styles: [String: NotificationStyles.Style] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Only on the notch", detail: "For each app below, set its alert style to None and keep Show in Notification Center on. macOS stops the banner in the corner; the notification still comes here. Don't turn off Allow Notifications: then nothing arrives at all.") {
                Button("Refresh") { reload() }.controlSize(.small)
            }
            if feed.access != .granted {
                Label("Allow Full Disk Access first (above), so win-tab can see which apps send notifications.", systemImage: "1.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            } else if feed.recentApps.isEmpty {
                Text("No notifications yet. Apps show up here after they send one.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            } else {
                let done = feed.recentApps.filter { styles[$0.bundleID.lowercased()]?.notchOnly == true }.count
                Text("\(done) of \(feed.recentApps.count) apps only on the notch")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(done == feed.recentApps.count ? .green : .secondary)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                ForEach(feed.recentApps, id: \.bundleID) { app in
                    AppStyleRow(bundleID: app.bundleID, count: app.count, style: styles[app.bundleID.lowercased()])
                }
            }
        }
        .onAppear(perform: reload)
        // Back from System Settings: show what changed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
    }

    private func reload() {
        CFPreferencesAppSynchronize("com.apple.ncprefs" as CFString)
        styles = NotificationStyles.read()
    }
}

private struct AppStyleRow: View {
    let bundleID: String
    let count: Int
    let style: NotificationStyles.Style?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = AppIcons.icon(bundleID: bundleID) { Image(nsImage: icon).resizable() } else { Image(systemName: "app.dashed").resizable() }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(NotificationFeed.appName(bundleID)).font(.system(size: 13, weight: .medium))
                Text("\(count) recent").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            chip
            if style?.notchOnly == true {
                Button("Settings…") { NotificationStyles.openSettings(for: bundleID) }.controlSize(.small).buttonStyle(.borderless)
            } else {
                Button(style == .some(.off) ? "Allow…" : "Turn Off Banners…") { NotificationStyles.openSettings(for: bundleID) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    @ViewBuilder private var chip: some View {
        // `.some(.none)`: the Style case, not a missing value.
        switch style {
        case .some(.none): pill("Notch only", .green)
        case .some(.banners): pill("Banners", .orange)
        case .some(.alerts): pill("Alerts", .orange)
        case .some(.off): pill("Turned off", .red)
        case nil: EmptyView()
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}
