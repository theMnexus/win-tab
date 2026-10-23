import AppKit
import Network
import SwiftUI
import UniformTypeIdentifiers

enum NotchTab: String, CaseIterable, Identifiable {
    case home, notifications, shelf, clipboard, timer, battery, system, ports, translate
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .timer: return "timer"
        case .battery: return "battery.75percent"
        case .notifications: return "bell.fill"
        case .system: return "cpu"
        case .ports: return "point.3.connected.trianglepath.dotted"
        case .translate: return "character.bubble"
        }
    }
    var label: String { self == .shelf ? "Files" : rawValue.capitalized }

    /// Tabs switched on in Settings → Notch → Content (Home is always there).
    @MainActor static var enabled: [NotchTab] {
        allCases.filter { $0 == .home || SwitchPreferences.shared.notchTabs.contains($0.rawValue) }
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var expanded = false
    /// Pointer on the collapsed island, before it opens: it swells a little as feedback.
    @Published var peeking = false
    /// A file is being dragged toward the island: it swells wider to catch it.
    @Published var dragNear = false
    @Published var tab: NotchTab = .home
    @Published var dropTargeted = false
    /// Files in the drag over the island (0 when it carries no file URLs).
    @Published var dropCount = 0
    /// A battery alert shown by the closed island for a few seconds.
    @Published var alert: NotchAlert?
    /// A reply field is open in the Notifications tab.
    @Published var replying = false
    /// A tab's height is being dragged (Notifications, Files, Translate).
    @Published var resizing = false
    /// Set by the island: redraws its shape right away when a drag bar changes a height, so the
    /// outline and the content move in the same frame (a Combine sink fires before the new value
    /// is stored, and hopping a turn left the outline a frame behind the pointer).
    var onResize: (() -> Void)?
}

/// Sizes for one display's island. On a display with a notch the collapsed island is the notch
/// itself; elsewhere it's a small pill hanging from the top edge.
struct NotchGeometry {
    /// The outward curve where the island meets the top edge.
    static let flare: CGFloat = 8
    static let pillSize = CGSize(width: 170, height: 28)
    /// Room around the island inside the panel for the shadow.
    static let margin: CGFloat = 24

    let hasNotch: Bool
    let notch: CGSize
    /// The open island's content size (Settings → Notch → Size).
    let content: CGSize
    /// Horizontal centre of the notch, in screen coordinates.
    let centerX: CGFloat
    let screenTop: CGFloat
    /// Settings → Notch → Tabs: a floating bar under the open island (like Droppy), or in its top row.
    let tabsBelow: Bool
    /// Room kept for the Notifications tab's extra height (its tallest); the height itself is live.
    let maxNotificationsExtra: CGFloat
    /// The Files tab grows the same way (Settings-free: its drag bar remembers the height).
    let maxFilesExtra: CGFloat
    let maxTranslateExtra: CGFloat
    static let tabBarHeight: CGFloat = 44
    static let tabBarGap: CGFloat = 8

    @MainActor
    init(screen: NSScreen) {
        let f = screen.frame
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            hasNotch = true
            notch = CGSize(width: r.minX - l.maxX, height: screen.safeAreaInsets.top)
            centerX = f.minX + (l.maxX + r.minX) / 2
        } else {
            hasNotch = false
            notch = Self.pillSize
            centerX = f.midX
        }
        screenTop = f.maxY
        content = SwitchPreferences.shared.notchSize.content
        tabsBelow = SwitchPreferences.shared.notchTabBar == .below
        maxNotificationsExtra = SwitchPreferences.shared.notchTabs.contains("notifications") ? CGFloat(NotificationFeed.maxTabExtra) : 0
        maxFilesExtra = SwitchPreferences.shared.notchTabs.contains("shelf") ? CGFloat(NotchTabHeights.maxExtra) : 0
        maxTranslateExtra = SwitchPreferences.shared.notchTabs.contains("translate") ? CGFloat(NotchTabHeights.maxExtra) : 0
    }

    /// Width of the wings beside the notch that show a live activity.
    var wing: CGFloat { notch.height + 10 }
    /// Widest the wings get (status items), for sizing the content that draws them.
    static let maxWing: CGFloat = 120

    /// `wing` is the width of each side wing (0 = just the notch).
    func collapsedSize(wing: CGFloat, peeking: Bool = false, dragNear: Bool = false) -> CGSize {
        let grow: CGFloat = peeking ? 14 : 0
        let catching: CGFloat = dragNear ? 1 : 0
        return CGSize(width: notch.width + wing * 2 + Self.flare * 2 + grow + catching * 80, height: notch.height + grow / 3 + catching * 16)
    }

    /// Closed island showing an alert: wide wings beside the notch, and in the expanded style a
    /// row of text under it.
    func alertSize(_ style: BatteryPreferences.NotchAlertStyle) -> CGSize {
        switch style {
        case .expanded: return CGSize(width: max(notch.width + 200, 360) + Self.flare * 2, height: notch.height + Self.alertRow)
        case .compact: return CGSize(width: notch.width + Self.compactWing * 2 + Self.flare * 2, height: notch.height)
        case .icon: return CGSize(width: notch.width + Self.iconWing * 2 + Self.flare * 2, height: notch.height)
        }
    }
    static let iconWing: CGFloat = 40
    static let alertRow: CGFloat = 50
    static let compactWing: CGFloat = 116

    /// The Notifications tab's extra height right now (dragging its bar changes it live).
    @MainActor var notificationsExtra: CGFloat { min(CGFloat(NotificationFeed.shared.tabExtra), maxNotificationsExtra) }

    /// Height a tab adds with its drag bar (Notifications, Files).
    @MainActor func extra(for tab: NotchTab) -> CGFloat {
        switch tab {
        case .notifications: return notificationsExtra
        case .shelf: return min(CGFloat(NotchTabHeights.shared.files), maxFilesExtra)
        case .translate: return min(CGFloat(NotchTabHeights.shared.translate), maxTranslateExtra)
        default: return 0
        }
    }

    /// The open island for a tab: tabs with a drag bar may be taller.
    @MainActor func expandedSize(for tab: NotchTab) -> CGSize {
        CGSize(width: content.width + Self.flare * 2, height: content.height + notch.height + extra(for: tab))
    }

    /// The tallest the open island can get, which the panel and content are sized for.
    var expandedSize: CGSize {
        CGSize(width: content.width + Self.flare * 2, height: content.height + notch.height + max(maxNotificationsExtra, maxFilesExtra, maxTranslateExtra))
    }

    /// Room under the island for the tab bar.
    var tabBarSpace: CGFloat { tabsBelow ? Self.tabBarGap + Self.tabBarHeight : 0 }

    /// The open island and the tab bar under it, in screen coordinates.
    @MainActor func openRect(for tab: NotchTab) -> CGRect {
        let r = rect(expandedSize(for: tab))
        return CGRect(x: r.minX, y: r.minY - tabBarSpace, width: r.width, height: r.height + tabBarSpace)
    }

    var panelFrame: CGRect {
        let s = expandedSize
        let w = s.width + Self.margin * 2, h = s.height + Self.margin + tabBarSpace
        return CGRect(x: centerX - w / 2, y: screenTop - h, width: w, height: h)
    }

    /// The island's rect in screen coordinates for a size.
    func rect(_ size: CGSize) -> CGRect {
        CGRect(x: centerX - size.width / 2, y: screenTop - size.height, width: size.width, height: size.height)
    }
}

/// Square top that flares into the screen edge, rounded bottom: the notch's own outline.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat = NotchGeometry.flare

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let b = min(bottomRadius, r.height / 2), f = flare
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.minY + f), control: CGPoint(x: r.minX + f, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + f, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + f + b, y: r.maxY), control: CGPoint(x: r.minX + f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - f - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - f, y: r.maxY - b), control: CGPoint(x: r.maxX - f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY + f))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - f, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct NotchOpenKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False while the island is closed: hidden timelines and animations pause.
    var notchOpen: Bool {
        get { self[NotchOpenKey.self] }
        set { self[NotchOpenKey.self] = newValue }
    }
}

/// What the closed island shows in wings beside the notch: a song, a timer, or the status items
/// chosen in Settings (time, date, battery, Wi-Fi); a song or timer takes the wings when there is one.
@MainActor
enum NotchActivity {
    enum Mode { case none, music, timer, status }

    static var mode: Mode {
        let prefs = SwitchPreferences.shared
        if prefs.notchShowActivity {
            if NowPlayingMonitor.shared.track?.playing == true { return .music }
            if NotchTimer.shared.isRunning { return .timer }
        }
        return prefs.notchStatusItems.isEmpty ? .none : .status
    }

    static var isShowing: Bool { mode != .none }

    /// Status items show: on their own, or beside a song or timer when that's allowed.
    static var showsStatus: Bool {
        let prefs = SwitchPreferences.shared
        guard !prefs.notchStatusItems.isEmpty else { return false }
        return mode == .status || prefs.notchStatusWithActivity
    }

    /// Width an item takes in its wing right now, or nil when it isn't shown.
    static func width(_ key: String) -> CGFloat? {
        let m = mode
        switch key {
        case "artwork": return m == .music ? 26 : m == .timer ? 16 : nil
        case "bars": return m == .music ? 18 : m == .timer ? 38 : nil
        default:
            guard showsStatus else { return nil }
            switch key {
            case "time": return 36
            case "date": return 46
            case "wifi": return 16
            case "battery": return 56
            default: return nil
            }
        }
    }

    static func shown(_ keys: [String]) -> [String] { keys.filter { width($0) != nil } }

    private static func sideWidth(_ keys: [String]) -> CGFloat {
        let widths = shown(keys).compactMap(width)
        return widths.reduce(0, +) + CGFloat(max(widths.count - 1, 0)) * 6
    }

    /// Width of each wing: what it holds, both sides matching so the notch stays centred.
    static func wing(_ g: NotchGeometry) -> CGFloat {
        let m = mode
        guard m != .none else { return 0 }
        let prefs = SwitchPreferences.shared
        let widest = max(sideWidth(prefs.notchLeftItems), sideWidth(prefs.notchRightItems))
        guard widest > 0 else { return 0 }
        return min(max(widest + 18, m == .status ? 0 : g.wing), NotchGeometry.maxWing)
    }
}

/// Wi-Fi, wired or offline, for the notch's status items. No location permission needed: it
/// only tells the kind of connection, not the network's name.
@MainActor
final class NetworkStatus: ObservableObject {
    static let shared = NetworkStatus()
    enum Kind { case wifi, wired, offline }
    @Published private(set) var kind: Kind = .wifi
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let kind: Kind = path.status != .satisfied ? .offline : path.usesInterfaceType(.wifi) ? .wifi : .wired
            DispatchQueue.main.async { NetworkStatus.shared.kind = kind }
        }
        monitor.start(queue: DispatchQueue(label: "win-tab.network"))
    }
}

/// What the open island shows: tabs and toggles in the notch row, the chosen tab below.
/// Drawn once and kept; the island around it is `NotchIslandView`.
struct NotchExpandedContent: View {
    @ObservedObject var state: NotchState
    let geometry: NotchGeometry
    /// For the tabs' live heights: without these the frame kept its old height while a drag bar
    /// moved, and the content jumped only when something else redrew.
    @ObservedObject private var feed = NotificationFeed.shared
    @ObservedObject private var heights = NotchTabHeights.shared
    @ObservedObject private var nowPlaying = NowPlayingMonitor.shared
    @ObservedObject private var keepAwake = KeepAwake.shared
    @ObservedObject private var battery = BatteryMonitor.shared
    @ObservedObject private var prefs = SwitchPreferences.shared

    private var tint: Color { nowPlaying.tint ?? prefs.accent.color }
    private var tabs: [NotchTab] { NotchTab.enabled }

    var body: some View {
        VStack(spacing: 10) {
            header.frame(height: geometry.notch.height)
            Group {
                switch tabs.contains(state.tab) ? state.tab : .home {
                case .home: NotchHomeView(tint: tint, showsSources: !geometry.tabsBelow)
                case .shelf: NotchFilesView(state: state)
                case .clipboard: NotchClipboardView(state: state)
                case .timer: NotchTimerView()
                case .battery: NotchBatteryView()
                case .notifications: NotchNotificationsView(state: state)
                case .system: NotchSystemView()
                case .ports: NotchPortsView()
                case .translate: NotchTranslateView(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(state.tab)
            .transition(.opacity.animation(.easeOut(duration: 0.15)))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        // The host is sized for the tallest tab; each tab fills only its own height.
        .frame(height: geometry.expandedSize(for: tabs.contains(state.tab) ? state.tab : .home).height, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(state.resizing ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: state.tab)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.notchOpen, state.expanded)
    }

    /// Tabs on the left of the notch, toggles on the right, nothing under the camera.
    private var header: some View {
        HStack(spacing: 4) {
            if geometry.tabsBelow {
                let shown = tabs.contains(state.tab) ? state.tab : .home
                if shown == .home && !nowPlaying.sources.isEmpty {
                    // Never past the left half: the real notch covers the middle of this row.
                    NowPlayingSources(tint: tint)
                        .frame(maxWidth: max((geometry.content.width - geometry.notch.width) / 2 - 24, 60), alignment: .leading)
                } else {
                    Label(shown.label, systemImage: shown.symbol)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                        .padding(.leading, 4)
                }
            } else {
                ForEach(tabs) { tab in
                    NotchIconButton(symbol: tab.symbol, selected: state.tab == tab, tint: tint, help: tab.label) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.tab = tab }
                    }
                }
            }
            Spacer(minLength: geometry.hasNotch ? geometry.notch.width : 12)
            // Notifications on or off from the notch itself (the same switch as Settings › Notch).
            NotchIconButton(symbol: feed.enabled ? "bell.fill" : "bell.slash", selected: feed.enabled, tint: tint,
                            help: feed.enabled ? "Notifications are on: click to turn them off" : "Notifications are off: click to turn them on") {
                feed.enabled.toggle()
            }
            if prefs.notchShowKeepAwake {
                NotchIconButton(symbol: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer", selected: keepAwake.isOn,
                                tint: .orange, help: keepAwake.isOn ? "Keep Awake is on" : "Keep the display awake") { keepAwake.toggle() }
            }
            if prefs.notchShowBattery, let b = battery.state {
                HStack(spacing: 3) {
                    Text("\(b.percent)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                    // Filled to the real level (a fixed symbol showed 26% as nearly full).
                    BatteryGlyph(percent: b.percent, charging: b.charging,
                                 color: b.percent <= 20 && !b.charging ? .red : b.charging ? .green : .white.opacity(0.85),
                                 showsPercent: false, height: 10)
                }
                .padding(.leading, 4)
            }
        }
    }
}

/// The closed island's wings: artwork and bars while music plays, or a running timer.
struct NotchCollapsedContent: View {
    @ObservedObject var state: NotchState
    let geometry: NotchGeometry
    @ObservedObject private var nowPlaying = NowPlayingMonitor.shared
    @ObservedObject private var timer = NotchTimer.shared
    @ObservedObject private var prefs = SwitchPreferences.shared

    @ObservedObject private var battery = BatteryMonitor.shared
    @ObservedObject private var network = NetworkStatus.shared
    @ObservedObject private var style = StylePreferences.shared

    private var mode: NotchActivity.Mode { NotchActivity.mode }
    /// Text and icons beside the closed notch, per Settings → Notch → Style.
    private var ink: Color { style.resolve(style.notchText, custom: style.notchTextColor, artwork: nowPlaying.tint) ?? .white }
    private var barsColor: Color { style.resolve(style.notchBars, custom: style.notchBarsColor, artwork: nowPlaying.tint) ?? tint }
    private var tint: Color { nowPlaying.tint ?? prefs.accent.color }

    var body: some View {
        let wing = NotchActivity.wing(geometry)
        // Exactly notch + two wings, centred: a flexible gap would push the wings past the island.
        HStack(spacing: 0) {
            leftWing.frame(width: wing)
            Color.clear.frame(width: geometry.notch.width)
            rightWing.frame(width: wing)
        }
        .frame(width: geometry.notch.width + wing * 2, height: geometry.notch.height)
        .frame(maxWidth: .infinity)
        .foregroundStyle(ink)
        .environment(\.colorScheme, .dark)
    }

    private var leftWing: some View {
        HStack(spacing: 6) {
            ForEach(NotchActivity.shown(prefs.notchLeftItems), id: \.self) { item($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 6)
    }

    private var rightWing: some View {
        HStack(spacing: 6) {
            ForEach(NotchActivity.shown(prefs.notchRightItems), id: \.self) { item($0) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private func item(_ key: String) -> some View {
        switch key {
        case "artwork":
            if mode == .timer {
                Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            } else {
                NotchArtwork(size: geometry.notch.height - 12, radius: 6)
            }
        case "bars":
            if mode == .timer {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(NotchTimer.format(timer.remaining(at: ctx.date)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.orange).minimumScaleFactor(0.6)
                }
            } else {
                EqualizerBars(color: barsColor, active: !state.expanded).frame(width: 16, height: 12)
            }
        case "time":
            TimelineView(.everyMinute) { ctx in Text(ctx.date, format: .dateTime.hour().minute()) }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
        case "date":
            TimelineView(.everyMinute) { ctx in Text(ctx.date, format: .dateTime.weekday(.abbreviated).day()) }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                .foregroundStyle(ink.opacity(0.7))
        case "wifi":
            Image(systemName: network.kind == .offline ? "wifi.slash" : network.kind == .wired ? "cable.connector" : "wifi")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(network.kind == .offline ? .red : ink.opacity(0.85))
        case "battery":
            if let b = battery.state {
                HStack(spacing: 3) {
                    Text("\(b.percent)%").font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    BatteryGlyph(percent: b.percent, charging: b.charging,
                                 color: b.percent <= 20 && !b.charging ? .red : b.charging ? .green : ink.opacity(0.85),
                                 showsPercent: false, height: 10)
                }
                .lineLimit(1)
            }
        default:
            EmptyView()
        }
    }
}

/// Round icon button with a hover highlight, used across the notch.
struct NotchIconButton: View {
    let symbol: String
    var selected = false
    var tint: Color = .white
    var size: CGFloat = 11
    var frame: CGFloat = 26
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(selected ? tint : .white.opacity(hovering ? 0.95 : 0.6))
                .frame(width: frame, height: frame * 0.8)
                .background(Capsule().fill(selected ? tint.opacity(0.22) : Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(help)
    }
}

struct NotchArtwork: View {
    let size: CGFloat
    let radius: CGFloat
    @ObservedObject private var nowPlaying = NowPlayingMonitor.shared

    /// Changes when the picture does: a new cover crossfades in.
    private var key: String {
        nowPlaying.artwork.map { "\(ObjectIdentifier($0).hashValue)" } ?? (nowPlaying.track?.bundleID ?? "-")
    }

    var body: some View {
        ZStack {
            face.id(key).transition(.opacity)
        }
        .animation(.smooth(duration: 0.4), value: key)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder private var face: some View {
        Group {
            if let image = nowPlaying.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let icon = nowPlaying.track.flatMap({ AppIcons.icon(bundleID: $0.bundleID) }) {
                Image(nsImage: icon).resizable().padding(size * 0.08)
                    .background(Color.white.opacity(0.08))
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// App icons by bundle ID, looked up once (views ask on every frame).
@MainActor
extension NSImage {
    /// An app icon as one bitmap. Workspace icons keep every size as a lazy representation and
    /// pick and rasterize one on each draw, which showed up as main-thread time on every
    /// ⌘-Tab selection step.
    nonisolated static func flattenedIcon(_ icon: NSImage) -> NSImage {
        let side: CGFloat = 256
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return icon }
        // Keep the icon's own point size: views that don't resize it lay it out at that size.
        return NSImage(cgImage: cg, size: icon.size)
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    /// Icons are flattened at 256 px; past this many the cache starts over (like `SwitchView.iconCache`).
    private static let limit = 64
    static func icon(bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        if cache.count >= limit { cache.removeAll() }
        let icon = NSImage.flattenedIcon(NSWorkspace.shared.icon(forFile: url.path))
        cache[bundleID] = icon
        return icon
    }
}

/// Bouncing bars while music plays. Core Animation runs the bounce on its own (render server),
/// so an always-visible live activity costs the app nothing per frame.
struct EqualizerBars: NSViewRepresentable {
    let color: Color
    var active = true

    final class BarsView: NSView {
        private let bars: [CALayer] = (0..<4).map { _ in CALayer() }
        private static let durations: [CFTimeInterval] = [0.42, 0.55, 0.36, 0.48]

        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            for (i, bar) in bars.enumerated() {
                bar.cornerRadius = 1.25
                bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer?.addSublayer(bar)
                let bounce = CABasicAnimation(keyPath: "transform.scale.y")
                bounce.fromValue = 0.25
                bounce.toValue = 1
                bounce.duration = Self.durations[i]
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bounce.timeOffset = Double(i) * 0.13
                bar.add(bounce, forKey: "bounce")
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let w: CGFloat = 2.5, gap: CGFloat = 2
            let total = CGFloat(bars.count) * w + CGFloat(bars.count - 1) * gap
            for (i, bar) in bars.enumerated() {
                bar.frame = CGRect(x: (bounds.width - total) / 2 + CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
            }
        }

        func update(color: NSColor, active: Bool) {
            for bar in bars { bar.backgroundColor = color.cgColor }
            // speed 0 freezes the animation where it is instead of tearing it down.
            layer?.speed = active ? 1 : 0
        }
    }

    func makeNSView(context: Context) -> BarsView { BarsView() }
    func updateNSView(_ view: BarsView, context: Context) { view.update(color: NSColor(color), active: active) }
}

// MARK: - Tabs

/// Now Playing: artwork, title and bars on top; the timeline; then big transport controls with
/// the player picker, open-app and volume at the ends.
private struct NotchHomeView: View {
    let tint: Color
    /// With the tabs in the top row, the playing apps sit above the song instead of beside the notch.
    var showsSources = false
    @Environment(\.notchOpen) private var open
    @ObservedObject private var nowPlaying = NowPlayingMonitor.shared
    @ObservedObject private var volume = SystemVolume.shared
    @State private var artHover = false

    var body: some View {
        let track = nowPlaying.track
        VStack(spacing: 7) {
            if showsSources && !nowPlaying.sources.isEmpty { NowPlayingSources(tint: tint) }
            HStack(spacing: 12) {
                NotchArtwork(size: showsSources && !nowPlaying.sources.isEmpty ? 44 : 54, radius: 13)
                    .overlay {
                        if artHover && track != nil {
                            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.black.opacity(0.4))
                                .overlay(Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 17)))
                        }
                    }
                    .scaleEffect(artHover ? 1.05 : 1)
                    .shadow(color: tint.opacity(track?.playing == true ? 0.5 : 0), radius: 12, y: 3)
                    .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { artHover = h } }
                    .onTapGesture { nowPlaying.openPlayer() }
                    .help(track.map { "Open \($0.player)" } ?? "")
                OpenPlayerTitle(track: track, subtitle: subtitle(track))
                    // A new song slides in instead of the text swapping in place.
                    .id(track.map { $0.bundleID + $0.title } ?? "")
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
                Spacer(minLength: 8)
                if track?.playing == true {
                    EqualizerBars(color: tint, active: open).frame(width: 22, height: 16)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .animation(.smooth(duration: 0.35), value: track.map { $0.bundleID + $0.title })
            .animation(.smooth(duration: 0.25), value: track?.playing)
            if let hint = nowPlaying.browserHint {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(hint.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if hint.opensAutomation {
                        Button("Open") { NSWorkspace.shared.open(NowPlayingMonitor.automationSettings) }
                            .buttonStyle(.plain).foregroundStyle(.white).underline()
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, minHeight: 14, alignment: .center)
                .transition(.opacity)
            } else if let hint = nowPlaying.controlHint {
                Label(hint, systemImage: "forward.end").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 14, alignment: .center)
                    .transition(.opacity)
            } else {
                timeline(track)
            }
            controls(track)
        }
        .onAppear { volume.refresh() }
    }

    private func subtitle(_ track: NowPlayingMonitor.Track?) -> String {
        guard let track else { return "Play music or a video in any app" }
        if !nowPlaying.canControl { return "\(track.player) · click the artwork to open it" }
        return track.artist.isEmpty ? track.player : track.artist
    }

    /// Elapsed, the bar (thicker under the pointer, click to seek), time left.
    private func timeline(_ track: NowPlayingMonitor.Track?) -> some View {
        // ~15 updates a second so the bar glides instead of stepping every half second.
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !open || track?.playing != true)) { ctx in
            let length = track?.duration ?? 0
            let position = length > 0 ? track?.position(at: ctx.date) ?? 0 : 0
            HStack(spacing: 10) {
                Text(NotchTimer.format(position)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                    .frame(width: 38, alignment: .leading)
                SeekBar(fraction: length > 0 ? position / length : 0, tint: .white) { f in
                    guard let track, nowPlaying.canSeek else { return }
                    nowPlaying.seek(to: track.duration * f)
                }
                Text("-" + NotchTimer.format(max(0, length - position))).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6)).frame(width: 42, alignment: .trailing)
            }
            .opacity(track == nil || length == 0 ? 0.35 : 1)
        }
    }

    private func controls(_ track: NowPlayingMonitor.Track?) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                playerMenu
                TransportButton(symbol: "arrow.up.forward.app", size: 13, help: "Open the player") { nowPlaying.openPlayer() }
                    .disabled(track == nil)
            }
            .frame(width: 110, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                TransportButton(symbol: "backward.fill", size: 20, help: "Previous") { nowPlaying.send(.previous) }
                TransportButton(symbol: track?.playing == true ? "pause.fill" : "play.fill", size: 27,
                                help: track?.playing == true ? "Pause" : "Play") { nowPlaying.send(.playpause) }
                TransportButton(symbol: "forward.fill", size: 20, help: "Next") { nowPlaying.send(.next) }
            }
            .disabled(!nowPlaying.canControl)
            .opacity(nowPlaying.canControl ? 1 : 0.35)
            Spacer(minLength: 0)
            volumeControl.frame(width: 110, alignment: .trailing)
        }
        .frame(height: 32)
    }

    /// Every app with something playing; the chosen one drives the rest.
    private var playerMenu: some View {
        Menu {
            if nowPlaying.sources.isEmpty { Text("Nothing is playing") }
            ForEach(nowPlaying.sources) { source in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { nowPlaying.select(source.bundleID) }
                } label: {
                    if source.bundleID == nowPlaying.track?.bundleID {
                        Label(source.name, systemImage: "checkmark")
                    } else {
                        Text(source.name + (source.audible ? "  ♪" : ""))
                    }
                }
            }
            if let track = nowPlaying.track {
                Divider()
                Button("Open \(track.player)") { nowPlaying.openPlayer() }
            }
        } label: {
            Group {
                if let id = nowPlaying.track?.bundleID, let icon = AppIcons.icon(bundleID: id) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "list.bullet").font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(.white.opacity(0.75))
        .help(nowPlaying.sources.count > 1 ? "\(nowPlaying.sources.count) players: choose one" : "Player")
    }

    /// System output volume, like the menu-bar control.
    private var volumeControl: some View {
        HStack(spacing: 4) {
            TransportButton(symbol: volume.muted || volume.volume == 0 ? "speaker.slash.fill" : volume.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill",
                            size: 12, help: volume.muted ? "Unmute" : "Mute") { volume.set(muted: !volume.muted) }
            Slider(value: Binding(get: { Double(volume.muted ? 0 : volume.volume) }, set: { volume.set(volume: Float($0)) }), in: 0...1)
                .controlSize(.mini).tint(.white).frame(width: 70)
                .disabled(!volume.adjustable)
        }
    }
}

/// Every app with something playing, as chips (bars on the ones making sound); the chosen one
/// drives Now Playing. Falls back to a count when they don't fit.
struct NowPlayingSources: View {
    let tint: Color
    @Environment(\.notchOpen) private var open
    @ObservedObject private var nowPlaying = NowPlayingMonitor.shared

    /// How much of each chip shows: names on all, only on the chosen one, or icons alone.
    private enum Detail { case full, chosen, icons }

    var body: some View {
        // Narrower and narrower rows until one fits beside the real notch, then a bare count.
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.chosen)
            row(.icons)
            Text("\(nowPlaying.sources.count) players").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
        }
        .frame(height: 20, alignment: .leading)
    }

    private func row(_ detail: Detail) -> some View {
        let shownID = nowPlaying.track?.bundleID
        return HStack(spacing: 4) {
            ForEach(nowPlaying.sources) { source in
                let selected = source.bundleID == shownID
                SourceChip(source: source, selected: selected, tint: tint, animate: open,
                           showsName: detail == .full || (detail == .chosen && selected)) {
                    // First click shows that player here; clicking the one already shown opens it.
                    if selected {
                        nowPlaying.open(bundleID: source.bundleID)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { nowPlaying.select(source.bundleID) }
                    }
                } openApp: {
                    nowPlaying.open(bundleID: source.bundleID)
                }
            }
        }
    }
}

/// One playing app: icon, name (when there's room), and bars while it's making sound.
private struct SourceChip: View {
    let source: NowPlayingMonitor.Source
    let selected: Bool
    let tint: Color
    var animate = true
    var showsName = true
    let action: () -> Void
    var openApp: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = AppIcons.icon(bundleID: source.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                }
                if showsName { Text(source.name).font(.system(size: 10, weight: .semibold)).lineLimit(1) }
                if source.audible && (showsName || selected) {
                    EqualizerBars(color: selected ? tint : .white.opacity(0.6), active: animate).frame(width: 10, height: 8).scaleEffect(0.7)
                }
            }
            .padding(.horizontal, showsName ? 7 : 6)
            .frame(height: 18)
            .foregroundStyle(selected ? .white : .white.opacity(hovering ? 0.9 : 0.6))
            .background(Capsule().fill(selected ? tint.opacity(0.3) : Color.white.opacity(hovering ? 0.14 : 0.07)))
            .overlay(Capsule().stroke(selected ? tint.opacity(0.6) : .clear, lineWidth: 1))
            // An icon-only chip still shows a sounding player: a small dot in the tint.
            .overlay(alignment: .topTrailing) {
                if source.audible && !showsName && !selected {
                    Circle().fill(tint).frame(width: 5, height: 5).offset(x: 1, y: -1)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .simultaneousGesture(TapGesture(count: 2).onEnded(openApp))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu { Button("Open \(source.name)", action: openApp) }
        .help(selected ? "Click to open \(source.name)" : "Show \(source.name) · double-click to open it")
    }
}

/// Song and artist; clicking them opens the player, with an arrow on hover saying so.
private struct OpenPlayerTitle: View {
    let track: NowPlayingMonitor.Track?
    let subtitle: String
    @ObservedObject private var nowPlaying = NowPlayingMonitor.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "Nothing playing").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(hovering ? 0.8 : 0.55)).lineLimit(1)
            }
            if hovering && track != nil {
                Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if track != nil { nowPlaying.openPlayer() } }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(track.map { "Open \($0.player)" } ?? "")
    }
}

/// A plain white glyph that grows under the pointer and dips when pressed.
private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(size >= 18 || hovering ? 0.95 : 0.65))
                .frame(width: max(size * 1.6, 28), height: max(size * 1.4, 28))
                .background(Circle().fill(.white.opacity(hovering ? 0.1 : 0)).frame(width: max(size * 1.7, 28)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .scaleEffect(hovering ? 1.08 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Timeline bar: thin at rest, thicker under the pointer; click to seek.
private struct SeekBar: View {
    let fraction: Double
    let tint: Color
    let seek: (Double) -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { g in
            let h: CGFloat = hovering ? 7 : 5
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(tint).frame(width: max(h, g.size.width * min(max(fraction, 0), 1)))
            }
            .frame(height: h)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in seek(min(max(v.location.x / g.size.width, 0), 1)) })
        }
        .frame(height: 14)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct NotchClipboardView: View {
    @ObservedObject var state: NotchState
    @ObservedObject private var history = ClipboardHistory.shared
    @State private var copiedID: UUID?
    @State private var filter: Filter = .all
    @State private var query = ""
    /// The search field is open: the notch takes the keyboard (like a reply) until it closes.
    @State private var searching = false
    @FocusState private var fieldFocused: Bool

    /// Quick filters over the history.
    enum Filter: String, CaseIterable, Identifiable {
        case all, today, pinned, links, text
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .today: return "Today"
            case .pinned: return "Pinned"
            case .links: return "Links"
            case .text: return "Text"
            }
        }

        func keeps(_ clip: ClipboardHistory.Clip) -> Bool {
            switch self {
            case .all: return true
            case .today: return clip.date.map(Calendar.current.isDateInToday) ?? false
            case .pinned: return clip.pinned
            case .links: return Self.isLink(clip.text)
            case .text: return !Self.isLink(clip.text)
            }
        }

        static func isLink(_ text: String) -> Bool {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.contains(where: \.isWhitespace), let url = URL(string: t), let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https", "ftp", "file", "mailto"].contains(scheme)
        }
    }

    var body: some View {
        if history.clips.isEmpty {
            Text("Text you copy shows up here. Click an item to copy it again.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let shown = history.clips.filter { filter.keeps($0) && matches($0) }
            VStack(spacing: 6) {
                filterBar
                ScrollView(.vertical, showsIndicators: false) {
                    // Lazy: up to 500 clips, and only the rows in view are built.
                    LazyVStack(spacing: 3) { ForEach(shown) { row($0) } }
                        .animation(.smooth(duration: 0.25), value: shown.map(\.id))
                }
                .overlay {
                    if shown.isEmpty {
                        Text(query.isEmpty ? "Nothing here for “\(filter.label)”." : "No clips match “\(query)”.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .onChange(of: state.expanded) { _, open in if !open { closeSearch(clear: false) } }
        }
    }

    private func matches(_ clip: ClipboardHistory.Clip) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { clip.text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// A small magnifier in the filter row; clicked, it widens into a field that takes the keyboard.
    private var searchBar: some View {
        let open = searching || !query.isEmpty
        return HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(open ? 0.7 : 0.6))
            if searching {
                TextField("Search", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit { if let first = history.clips.first(where: { filter.keeps($0) && matches($0) }) { history.copy(first); copiedID = first.id } }
                    .onExitCommand { closeSearch(clear: true) }
            } else if !query.isEmpty {
                Text(query).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            }
            if open {
                Button { closeSearch(clear: true) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, open ? 8 : 0)
        .frame(width: open ? 150 : 20, height: 20, alignment: open ? .leading : .center)
        .background(Capsule().fill(Color.white.opacity(open ? 0.12 : 0.06)))
        .contentShape(Capsule())
        .onTapGesture { if !searching { openSearch() } }
        .animation(.smooth(duration: 0.22), value: open)
        .help("Search clipboard")
    }

    private func openSearch() {
        searching = true
        state.replying = true
        // The panel becomes key on the next turn; focus after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
    }

    private func closeSearch(clear: Bool) {
        if clear { query = "" }
        searching = false
        fieldFocused = false
        if state.replying { state.replying = false }
    }

    private var filterBar: some View {
        HStack(spacing: 5) {
            ForEach(Filter.allCases) { f in
                Button { withAnimation(.smooth(duration: 0.2)) { filter = f } } label: {
                    Text(f.label).font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 9).frame(height: 20)
                        .foregroundStyle(filter == f ? .white : .white.opacity(0.6))
                        .background(Capsule().fill(filter == f ? Color.white.opacity(0.2) : Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 6)
            searchBar
            Button("Clear") { history.clearUnpinned() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .help("Removes everything except pinned items")
        }
    }

    private func row(_ clip: ClipboardHistory.Clip) -> some View {
        HStack(spacing: 8) {
            if Filter.isLink(clip.text) {
                Image(systemName: "link").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
            Text(clip.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if copiedID == clip.id {
                Text("Copied").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
            } else if let date = clip.date {
                Text(Self.age(date)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.4))
            }
            Button { history.togglePin(clip) } label: {
                Image(systemName: clip.pinned ? "pin.fill" : "pin").font(.system(size: 10))
                    .foregroundStyle(clip.pinned ? .orange : .white.opacity(0.45))
            }
            .buttonStyle(.plain)
            Button { history.remove(clip) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
        .contentShape(Rectangle())
        .onTapGesture {
            history.copy(clip)
            copiedID = clip.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedID == clip.id { copiedID = nil } }
        }
    }

    /// "now", "5m", "3h", "Yesterday", "2d".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if Calendar.current.isDateInToday(date) { return "\(Int(s / 3600))h" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return "\(Int(s / 86_400))d"
    }
}

private struct NotchTimerView: View {
    @ObservedObject private var timer = NotchTimer.shared

    var body: some View {
        if timer.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let remaining = timer.remaining(at: ctx.date)
                HStack(spacing: 22) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 6)
                        Circle().trim(from: 0, to: timer.total > 0 ? remaining / timer.total : 0)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NotchTimer.format(remaining))
                            .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                        Button("Stop") { timer.stop() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.15)))
                    }
                    Spacer()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Start a timer").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    ForEach(NotchTimer.presets, id: \.self) { m in
                        Button { timer.start(minutes: m) } label: {
                            Text("\(m) min").font(.system(size: 12, weight: .medium))
                                .frame(width: 70, height: 40)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("The notch shows the countdown and chimes when it's done.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}
