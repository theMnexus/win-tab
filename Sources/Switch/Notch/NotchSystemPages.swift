import AppKit
import Darwin
import SwiftUI
import SystemConfiguration

enum SystemFormat {
    static func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        return g >= 10 ? String(format: "%.0f GB", g) : g >= 1 ? String(format: "%.1f GB", g) : String(format: "%.0f MB", g * 1024)
    }

    static func rate(_ bps: Double) -> String {
        bps >= 1_048_576 ? String(format: "%.1f MB/s", bps / 1_048_576) : String(format: "%.0f KB/s", bps / 1024)
    }

    /// "VN" → 🇻🇳.
    static func flag(_ code: String) -> String {
        String(String.UnicodeScalarView(code.uppercased().unicodeScalars.compactMap { Unicode.Scalar(127_397 + $0.value) }))
    }
}

/// Small capsule button, filled when on.
struct SystemPill: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? .black : .white.opacity(0.7))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.white.opacity(0.9) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Network

/// Local and public address, the country it shows up from, and whether a VPN carries traffic.
@MainActor
final class NetworkInfo: ObservableObject {
    static let shared = NetworkInfo()
    /// Settings → Notch → System: look the public address up at ipinfo.io (sends it your IP).
    static let lookupKey = "switch.notch.system.publicIP"

    struct Public: Equatable {
        let ip: String
        let country: String
        let city: String
        let org: String
    }

    struct Local: Equatable {
        let interface: String
        let ip: String
    }

    @Published private(set) var publicInfo: Public?
    @Published private(set) var lookingUp = false
    @Published private(set) var lookupFailed = false
    @Published private(set) var local: Local?
    /// The VPN interface that has an address, or nil.
    @Published private(set) var vpn: String?
    @Published private(set) var vpnIsPrimary = false

    private var lastKey = ""
    private var fetchedAt: Date?
    private static let maxAge: TimeInterval = 600
    private static let vpnPrefixes = ["utun", "ipsec", "ppp", "wg", "tun", "tap"]

    var lookupEnabled: Bool { UserDefaults.standard.object(forKey: Self.lookupKey) as? Bool ?? true }

    /// Re-reads the interfaces; looks the public address up again when the network changed,
    /// the last lookup is old, or `force`.
    func refresh(force: Bool = false) {
        let (primary, addresses) = Self.interfaces()
        local = primary.flatMap { name in addresses[name].map { Local(interface: name, ip: $0) } }
        let tunnel = addresses.keys.sorted().first { name in Self.vpnPrefixes.contains { name.hasPrefix($0) } }
        vpnIsPrimary = primary.map { name in Self.vpnPrefixes.contains { name.hasPrefix($0) } } ?? false
        vpn = vpnIsPrimary ? primary : tunnel
        guard lookupEnabled else { publicInfo = nil; return }
        let key = "\(primary ?? "")|\(local?.ip ?? "")|\(vpn ?? "")"
        let stale = fetchedAt.map { Date().timeIntervalSince($0) > Self.maxAge } ?? true
        guard force || key != lastKey || stale, !lookingUp else { return }
        lastKey = key
        lookup()
    }

    private func lookup() {
        lookingUp = true
        var request = URLRequest(url: URL(string: "https://ipinfo.io/json")!, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let parsed = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.flatMap(Self.parse)
            if let error { NSLog("win-tab: public IP lookup failed: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let info = NetworkInfo.shared
                    info.lookingUp = false
                    info.lookupFailed = parsed == nil
                    if let parsed {
                        info.publicInfo = parsed
                        info.fetchedAt = Date()
                    }
                }
            }
        }.resume()
    }

    /// Only well-formed answers: an IP address and a two-letter country.
    private nonisolated static func parse(_ json: [String: Any]) -> Public? {
        guard let ip = json["ip"] as? String, ip.count <= 45, ip.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }),
              let country = json["country"] as? String, country.count == 2, country.allSatisfy(\.isLetter) else { return nil }
        // "AS7552 Viettel Group" → "Viettel Group".
        let org = (json["org"] as? String ?? "").split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        return Public(ip: ip, country: country.uppercased(), city: String((json["city"] as? String ?? "").prefix(40)), org: String(org.prefix(40)))
    }

    /// The primary IPv4 interface and every interface's IPv4 address (link-local skipped).
    private static func interfaces() -> (String?, [String: String]) {
        var primary: String?
        if let store = SCDynamicStoreCreate(nil, "win-tab" as CFString, nil, nil),
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            primary = global["PrimaryInterface"] as? String
        }
        var out: [String: String] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (primary, out) }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: p.pointee.ifa_name)
            guard name != "lo0", !ip.hasPrefix("169.254.") else { continue }
            out[name] = ip
        }
        return (primary, out)
    }
}

/// Flag and public IP, place and provider, VPN state, local address and traffic.
struct NotchSystemNetworkPage: View {
    let snapshot: SystemSnapshot
    @ObservedObject private var net = NetworkInfo.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(net.publicInfo.map { SystemFormat.flag($0.country) } ?? "🌐").font(.system(size: 30))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(publicIP).font(.system(size: 14, weight: .bold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                        if net.publicInfo != nil {
                            Button(action: copy) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Copy the public IP")
                        }
                    }
                    Text(place).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { net.refresh(force: true) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(net.lookingUp ? 360 : 0))
                        .animation(net.lookingUp ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: net.lookingUp)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .help("Look the address up again")
            }
            HStack(spacing: 6) {
                Image(systemName: net.vpn == nil ? "shield.slash" : "lock.shield.fill")
                Text(vpnText).lineLimit(1)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(net.vpn == nil ? .white.opacity(0.55) : .green)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill((net.vpn == nil ? Color.white : Color.green).opacity(0.12)))
            HStack(spacing: 12) {
                Label(net.local.map { "\($0.ip) · \($0.interface)" } ?? "Offline", systemImage: "network")
                    .foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Spacer(minLength: 0)
                Label(SystemFormat.rate(snapshot.netIn), systemImage: "arrow.down").foregroundStyle(.cyan)
                Label(SystemFormat.rate(snapshot.netOut), systemImage: "arrow.up").foregroundStyle(.pink)
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
        }
        .onAppear { net.refresh() }
    }

    private var publicIP: String {
        if let p = net.publicInfo { return p.ip }
        if !net.lookupEnabled { return "Lookup off" }
        return net.lookingUp ? "Looking up…" : net.lookupFailed ? "No answer" : "–"
    }

    private var place: String {
        guard let p = net.publicInfo else { return net.lookupEnabled ? "Public address via ipinfo.io" : "Turn on in Settings → Notch → System" }
        let country = Locale.current.localizedString(forRegionCode: p.country) ?? p.country
        return [p.city.isEmpty ? nil : p.city, country, p.org.isEmpty ? nil : p.org].compactMap { $0 }.joined(separator: " · ")
    }

    private var vpnText: String {
        guard let vpn = net.vpn else { return "No VPN" }
        // Not the primary route: a split tunnel (or a dev tool's tunnel) carrying only some traffic.
        return net.vpnIsPrimary ? "VPN on · all traffic (\(vpn))" : "VPN tunnel · \(vpn) · some traffic"
    }

    private func copy() {
        guard let ip = net.publicInfo?.ip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - Optimize

/// Things that actually free memory or CPU: quit apps that have no windows, hide the rest so
/// App Nap slows them, Low Power Mode. No "RAM cleaning": macOS manages free memory itself.
struct NotchSystemOptimizePage: View {
    let snapshot: SystemSnapshot
    @ObservedObject private var battery = BatteryMonitor.shared
    @State private var hidOthers = false
    /// "Quit all" asks once: the first click lists the apps, the second quits them.
    @State private var confirming = false

    /// Regular apps with no window anywhere (any Space, minimized included), biggest first.
    /// Apps pinned in the ⌘-Tab picker are kept (tray apps like Zalo you want running).
    private var idle: [SystemSnapshot.App] {
        guard let withWindows = WindowStore.shared.current?.windows.allPIDs else { return [] }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pinned = SwitchPreferences.shared.pinnedBundleIDs
        return snapshot.apps
            .filter { !withWindows.contains($0.pid) && $0.pid != front && !pinned.contains($0.bundleID ?? "") }
            .sorted { $0.memory > $1.memory }
    }

    var body: some View {
        let idle = self.idle
        let freed = idle.reduce(0) { $0 + $1.memory }
        VStack(alignment: .leading, spacing: 6) {
            OptimizeRow(symbol: "rectangle.on.rectangle.slash", tint: .orange,
                        title: idle.isEmpty ? "No idle apps" : "\(idle.count) idle apps",
                        detail: idle.isEmpty ? "Every app has a window open"
                            : confirming ? idle.map(\.name).joined(separator: ", ") : "No windows · frees ~\(SystemFormat.gb(freed)) · pinned apps kept",
                        icons: idle.prefix(3).compactMap(\.bundleID),
                        action: idle.isEmpty ? nil : (confirming ? "Quit \(idle.count)?" : "Quit all", {
                            if confirming { quit(idle) }
                            withAnimation(.easeOut(duration: 0.15)) { confirming.toggle() }
                        }))
            OptimizeRow(symbol: "moon.zzz.fill", tint: .indigo,
                        title: "Hide other apps", detail: "App Nap slows them down",
                        action: (hidOthers ? "Hidden" : "Hide", {
                            NSWorkspace.shared.hideOtherApplications()
                            hidOthers = true
                        }))
            if let b = battery.state {
                OptimizeRow(symbol: "leaf.fill", tint: .yellow, title: "Low Power Mode",
                            detail: pressureText,
                            action: (b.lowPowerMode ? "Turn off" : "Turn on", { battery.setLowPowerMode(!b.lowPowerMode) }))
            } else {
                OptimizeRow(symbol: "memorychip", tint: .blue, title: "Memory pressure", detail: pressureText)
            }
        }
        .onAppear { WindowStore.shared.refresh() }
    }

    private var pressureText: String {
        switch snapshot.pressure {
        case 4...: return "Memory pressure critical"
        case 2...3: return "Memory pressure high"
        default: return "Memory normal · saves battery"
        }
    }

    private func quit(_ apps: [SystemSnapshot.App]) {
        for app in apps { NSRunningApplication(processIdentifier: app.pid)?.terminate() }
        SystemMonitor.shared.refreshSoon()
    }
}

private struct OptimizeRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var icons: [String] = []
    var action: (String, () -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: -4) {
                ForEach(icons, id: \.self) { bid in
                    if let icon = AppIcons.icon(bundleID: bid) { Image(nsImage: icon).resizable().frame(width: 15, height: 15) }
                }
            }
            if let action {
                Button(action: action.1) {
                    Text(action.0)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(tint.opacity(hovering ? 1 : 0.85)))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
    }
}
