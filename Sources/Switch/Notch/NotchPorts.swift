import AppKit
import SwiftUI

/// Settings → Notch → Ports: what the Ports tab leaves out, and what Stop asks about first.
@MainActor
final class PortRules: ObservableObject {
    static let shared = PortRules()
    private static let hiddenKey = "switch.notch.ports.hidden"
    private static let protectedKey = "switch.notch.ports.protected"
    private static let hideBackgroundKey = "switch.notch.ports.hideBackground"
    static let defaultProtected = ["postgres", "redis-server", "mongod", "mysqld", "mysql", "mariadbd"]

    /// Ports ("8317") or program / folder names ("cliproxyapi", "linear-ui"), never listed.
    @Published var hidden: [String] { didSet { UserDefaults.standard.set(hidden, forKey: Self.hiddenKey) } }
    /// Program names Stop asks about before ending them.
    @Published var protected: [String] { didSet { UserDefaults.standard.set(protected, forKey: Self.protectedKey) } }
    /// Leave out services launchd started (at login, `brew services`): not something you ran.
    @Published var hideBackground: Bool { didSet { UserDefaults.standard.set(hideBackground, forKey: Self.hideBackgroundKey) } }

    private init() {
        let d = UserDefaults.standard
        hidden = d.stringArray(forKey: Self.hiddenKey) ?? []
        protected = d.stringArray(forKey: Self.protectedKey) ?? Self.defaultProtected
        hideBackground = d.object(forKey: Self.hideBackgroundKey) as? Bool ?? true
    }

    func shows(_ server: DevServer) -> Bool {
        if hideBackground && server.background { return false }
        return !hidden.contains { rule in
            if let port = Int(rule) { return server.ports.contains(port) }
            return rule.caseInsensitiveCompare(server.program) == .orderedSame || rule.caseInsensitiveCompare(server.name) == .orderedSame
        }
    }

    func protects(_ server: DevServer) -> Bool {
        protected.contains { $0.caseInsensitiveCompare(server.program) == .orderedSame }
    }

    func hide(_ server: DevServer) {
        guard !hidden.contains(server.name) else { return }
        hidden.append(server.name)
    }
}

/// Scans for dev servers only while the Ports tab is on screen.
@MainActor
final class PortsMonitor: ObservableObject {
    static let shared = PortsMonitor()

    @Published private(set) var servers: [DevServer] = []
    @Published private(set) var scanned = false

    private let queue = DispatchQueue(label: "win-tab.ports", qos: .utility)
    private var timer: Timer?
    private static let interval: TimeInterval = 3

    func setActive(_ active: Bool) {
        guard active != (timer != nil) else { return }
        if active {
            scan()
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scan() }
            }
            t.tolerance = Self.interval * 0.1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func stop(_ server: DevServer, force: Bool) {
        // Gone at once; the next scan brings it back if it ignored the signal.
        servers.removeAll { $0.pid == server.pid }
        queue.async { [weak self] in
            PortScanner.stop(server.pid, force: force)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.scan() }
        }
    }

    private func scan() {
        queue.async { [weak self] in
            let found = PortScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanned = true
                if found != self.servers { withAnimation(.easeOut(duration: 0.2)) { self.servers = found } }
            }
        }
    }
}

/// Every dev server on the Mac, like WhatThePort: the port, the folder it runs from, its
/// command and git branch, how long it's been up and the memory it holds. Click a row to open
/// it in the browser; Stop ends it and everything it started.
struct NotchPortsView: View {
    @ObservedObject private var monitor = PortsMonitor.shared
    @ObservedObject private var rules = PortRules.shared
    @Environment(\.notchOpen) private var notchOpen
    @State private var shown = false

    var body: some View {
        let servers = monitor.servers.filter(rules.shows)
        let hiddenCount = monitor.servers.count - servers.count
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(servers.isEmpty ? "Dev servers" : "\(servers.count) running")
                    .font(.system(size: 11, weight: .semibold))
                if !servers.isEmpty {
                    Text("· \(SystemFormat.gb(servers.reduce(0) { $0 + $1.memory })) memory")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                if hiddenCount > 0 {
                    Text("· \(hiddenCount) hidden").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        .help("Left out in Settings → Notch → Ports")
                }
                Spacer(minLength: 0)
                Text("Click a row to open it · ⌥-click Stop to force")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4))
            }
            if servers.isEmpty {
                empty
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(servers) { PortRow(server: $0, protected: rules.protects($0)) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { shown = true; monitor.setActive(notchOpen) }
        .onDisappear { shown = false; monitor.setActive(false) }
        .onChange(of: notchOpen) { _, open in monitor.setActive(open && shown) }
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 20)).foregroundStyle(.white.opacity(0.4))
            Text(monitor.scanned ? (monitor.servers.isEmpty ? "No dev servers running" : "Everything running is hidden") : "Looking…")
                .font(.system(size: 12, weight: .semibold))
            Text("Start one in a terminal (npm run dev, python -m http.server…) and it shows up here.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Port, name and what's running, memory, then Folder / Open / Stop on hover.
private struct PortRow: View {
    let server: DevServer
    /// On the Never stop list: Stop asks once first.
    let protected: Bool
    @State private var hovering = false
    /// Protected servers ask once before stopping.
    @State private var confirming = false

    /// Past this a server is probably leaking (WhatThePort's threshold).
    private static let heavy: UInt64 = 2 << 30

    private var url: URL? { server.ports.first.flatMap { URL(string: "http://localhost:\($0)") } }
    private var tint: Color { protected ? .orange : .cyan }

    var body: some View {
        HStack(spacing: 8) {
            Text(server.ports.first.map(String.init) ?? "–")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 48, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.14)))
                .overlay(alignment: .topTrailing) {
                    if server.ports.count > 1 {
                        Text("+\(server.ports.count - 1)").font(.system(size: 7.5, weight: .bold)).padding(.horizontal, 2)
                            .background(Capsule().fill(.white.opacity(0.25))).offset(x: 4, y: -4)
                    }
                }
                .help(server.ports.map(String.init).joined(separator: ", "))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(server.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if let agent = server.agent { tag(agent, .purple) }
                    if protected { tag("protected", .orange) }
                }
                Text(detail).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovering {
                HStack(spacing: 4) {
                    icon("folder", help: "Show \(server.folder) in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: server.folder)])
                    }
                    icon("eye.slash", help: "Hide \(server.name) from this list (Settings → Notch → Ports brings it back)") {
                        PortRules.shared.hide(server)
                    }
                    if !protected, let url {
                        icon("arrow.up.right.square", help: "Open \(url.absoluteString)") { NSWorkspace.shared.open(url) }
                    }
                    Button(action: stop) {
                        Text(confirming ? "Stop?" : "Stop")
                            .font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.red.opacity(0.8)))
                    }
                    .buttonStyle(.plain)
                    .help(protected ? "Stop this protected server (asks once)" : "Stop it and everything it started (⌥-click forces)")
                }
                .transition(.opacity)
            }
            Text(SystemFormat.gb(server.memory))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(server.memory > Self.heavy ? .orange : .white.opacity(0.75))
                .frame(width: 52, alignment: .trailing)
                .help(server.memory > Self.heavy ? "Over 2 GB: it may be leaking memory" : "Memory used by it and everything it started")
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.09 : 0.04)))
        .contentShape(Rectangle())
        .onTapGesture { if !protected, let url { NSWorkspace.shared.open(url) } }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
            if !h { confirming = false }
        }
        .help(server.folder)
    }

    private var detail: String {
        [server.command, server.branch.map { "⎇ \($0)" }, "up \(Self.uptime(since: server.started))"].compactMap { $0 }.joined(separator: " · ")
    }

    private func stop() {
        if protected && !confirming {
            confirming = true
            return
        }
        PortsMonitor.shared.stop(server, force: NSEvent.modifierFlags.contains(.option))
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 8.5, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// "5m", "3h 12m", "1d 11h".
    static func uptime(since start: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
