import AppKit
import SwiftUI

/// How one alert shows: where, with a glow, whether it stays until closed, and its sound.
struct AlertStyle: Codable, Equatable {
    enum Position: String, Codable, CaseIterable, Identifiable {
        case notch, center
        var id: String { rawValue }
        var label: String { self == .notch ? "Notch" : "Center of Screen" }
    }

    var position: Position = .notch
    var glow = true
    var persistent = false
    var sound = "Funk"

    /// "Notch • Border Glow • Persistent • Sound" for the alert rows.
    var summary: String {
        [position.label, glow ? "Border Glow" : nil, persistent ? "Persistent" : nil, sound == "None" ? nil : "Sound"]
            .compactMap { $0 }.joined(separator: " • ")
    }
}

/// A low-battery or charged alert at one level.
struct LevelAlert: Codable, Equatable, Identifiable {
    var id = UUID()
    var level: Int
    var style: AlertStyle
}

/// Settings → Battery → General and Alerts. Stored under "switch.battery.".
@MainActor
final class BatteryPreferences: ObservableObject {
    static let shared = BatteryPreferences()

    enum MenuBarStyle: String, CaseIterable, Identifiable {
        case minimal, colour
        var id: String { rawValue }
        var label: String { self == .minimal ? "Minimal" : "Colour" }
    }

    enum BubbleSize: String, CaseIterable, Identifiable {
        case smaller, standard, larger
        var id: String { rawValue }
        var label: String { self == .standard ? "Default" : rawValue.capitalized }
        var scale: CGFloat { self == .smaller ? 0.85 : self == .larger ? 1.15 : 1 }
    }

    /// Look of the alert bubble.
    enum BubbleTheme: String, CaseIterable, Identifiable {
        case glass, minimal, vivid
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// Notch alerts: a row of text under the notch, or only the wings beside it.
    enum NotchAlertStyle: String, CaseIterable, Identifiable {
        case expanded, compact, icon
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum GlowStrength: String, CaseIterable, Identifiable {
        case subtle, standard, strong
        var id: String { rawValue }
        var label: String { self == .standard ? "Default" : rawValue.capitalized }
    }

    static let sounds = ["None", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    static let alertDurationRange: ClosedRange<Double> = 2...10

    @Published var alertsEnabled: Bool { didSet { save(alertsEnabled, "alerts") } }
    /// Highest level first.
    @Published var lowAlerts: [LevelAlert] { didSet { saveJSON(lowAlerts, "lowAlerts") } }
    @Published var chargedAlerts: [LevelAlert] { didSet { saveJSON(chargedAlerts, "chargedAlerts") } }
    @Published var plugAlert: Bool { didSet { save(plugAlert, "plugAlert") } }
    @Published var plugStyle: AlertStyle { didSet { saveJSON(plugStyle, "plugStyle") } }
    @Published var unplugAlert: Bool { didSet { save(unplugAlert, "unplugAlert") } }
    @Published var unplugStyle: AlertStyle { didSet { saveJSON(unplugStyle, "unplugStyle") } }
    @Published var accessoryAlert: Bool { didSet { save(accessoryAlert, "accessoryAlert") } }
    @Published var accessoryLevel: Int { didSet { save(accessoryLevel, "accessoryLevel") } }
    @Published var accessoryStyle: AlertStyle { didSet { saveJSON(accessoryStyle, "accessoryStyle") } }
    @Published var bubbleSize: BubbleSize { didSet { save(bubbleSize.rawValue, "bubbleSize") } }
    @Published var glowStrength: GlowStrength { didSet { save(glowStrength.rawValue, "glowStrength") } }
    @Published var bubbleTheme: BubbleTheme { didSet { save(bubbleTheme.rawValue, "bubbleTheme") } }
    @Published var notchAlertStyle: NotchAlertStyle { didSet { save(notchAlertStyle.rawValue, "notchAlertStyle") } }
    @Published var alertDuration: Double { didSet { save(alertDuration, "alertDuration") } }
    @Published var menuBarIcon: Bool { didSet { save(menuBarIcon, "menuBarIcon") } }
    @Published var menuBarStyle: MenuBarStyle { didSet { save(menuBarStyle.rawValue, "menuBarStyle") } }
    @Published var menuBarPercent: Bool { didSet { save(menuBarPercent, "menuBarPercent") } }

    private init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ f: Bool) -> Bool { d.object(forKey: Self.key(k)) as? Bool ?? f }
        func int(_ k: String, _ f: Int) -> Int { d.object(forKey: Self.key(k)) as? Int ?? f }
        func text(_ k: String, _ f: String) -> String { d.string(forKey: Self.key(k)) ?? f }
        func json<T: Decodable>(_ k: String, _ f: T) -> T {
            d.data(forKey: Self.key(k)).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? f
        }
        // Earlier builds kept bare levels; carry them over.
        let oldLow = (d.array(forKey: Self.key("lowLevels")) as? [Int]) ?? [20, 10, 5]
        let lowDefaults = oldLow.sorted(by: >).map { level in
            LevelAlert(level: level, style: AlertStyle(position: level > 10 ? .notch : .center, glow: true, persistent: level <= 5,
                                                       sound: level <= 5 ? "Basso" : "Funk"))
        }
        alertsEnabled = bool("alerts", true)
        lowAlerts = json("lowAlerts", lowDefaults)
        chargedAlerts = json("chargedAlerts", [LevelAlert(level: int("highLevel", 80), style: AlertStyle(glow: false, sound: "Glass"))])
        plugAlert = bool("plugAlert", true)
        plugStyle = json("plugStyle", AlertStyle(glow: false, sound: "Pop"))
        unplugAlert = bool("unplugAlert", true)
        unplugStyle = json("unplugStyle", AlertStyle(glow: false, sound: "Tink"))
        accessoryAlert = bool("accessoryAlert", true)
        accessoryLevel = int("accessoryLevel", 20)
        accessoryStyle = json("accessoryStyle", AlertStyle(glow: false, sound: "Purr"))
        bubbleSize = BubbleSize(rawValue: text("bubbleSize", "")) ?? .standard
        glowStrength = GlowStrength(rawValue: text("glowStrength", "")) ?? .standard
        bubbleTheme = BubbleTheme(rawValue: text("bubbleTheme", "")) ?? .glass
        notchAlertStyle = NotchAlertStyle(rawValue: text("notchAlertStyle", "")) ?? .expanded
        alertDuration = d.object(forKey: Self.key("alertDuration")) as? Double ?? 4
        menuBarIcon = bool("menuBarIcon", false)
        menuBarStyle = MenuBarStyle(rawValue: text("menuBarStyle", "")) ?? .colour
        menuBarPercent = bool("menuBarPercent", true)
    }

    static let levelRange = 1...100

    /// Why `level` can't be used for a new or changed alert, or nil when it can.
    func problem(with level: Int, charged: Bool, ignoring id: UUID? = nil) -> String? {
        guard Self.levelRange.contains(level) else { return "Enter a level from 1 to 100%." }
        let taken = (charged ? chargedAlerts : lowAlerts).contains { $0.level == level && $0.id != id }
        return taken ? "There's already an alert at \(level)%." : nil
    }

    /// Adds an alert at any level you type; returns why not, or nil when added.
    @discardableResult
    func addAlert(level: Int, charged: Bool) -> String? {
        if let problem = problem(with: level, charged: charged) { return problem }
        let alert = LevelAlert(level: level, style: AlertStyle(position: .notch, glow: !charged, sound: charged ? "Glass" : "Funk"))
        if charged { chargedAlerts = Self.sorted(chargedAlerts + [alert], charged: true) }
        else { lowAlerts = Self.sorted(lowAlerts + [alert], charged: false) }
        return nil
    }

    /// Moves an alert to another level, keeping the list in order; false when the level is taken or out of range.
    @discardableResult
    func setLevel(_ level: Int, of id: UUID, charged: Bool) -> Bool {
        guard problem(with: level, charged: charged, ignoring: id) == nil else { return false }
        let update = { (list: [LevelAlert]) in list.map { $0.id == id ? LevelAlert(id: $0.id, level: level, style: $0.style) : $0 } }
        if charged { chargedAlerts = Self.sorted(update(chargedAlerts), charged: true) }
        else { lowAlerts = Self.sorted(update(lowAlerts), charged: false) }
        return true
    }

    /// Low alerts highest first (the order they fire in); charged lowest first.
    private static func sorted(_ list: [LevelAlert], charged: Bool) -> [LevelAlert] {
        list.sorted { charged ? $0.level < $1.level : $0.level > $1.level }
    }

    var rules: BatteryAlertRules.Settings {
        guard alertsEnabled else { return .init(low: [], charged: [], plug: false, unplug: false, accessory: nil) }
        return .init(low: lowAlerts.map(\.level), charged: chargedAlerts.map(\.level), plug: plugAlert, unplug: unplugAlert,
                     accessory: accessoryAlert ? accessoryLevel : nil)
    }

    func style(for event: BatteryEvent) -> AlertStyle {
        switch event {
        case .low(let level): return lowAlerts.first { $0.level == level }?.style ?? AlertStyle()
        case .charged(let level): return chargedAlerts.first { $0.level == level }?.style ?? AlertStyle(glow: false, sound: "Glass")
        case .pluggedIn: return plugStyle
        case .unplugged: return unplugStyle
        case .accessoryLow: return accessoryStyle
        }
    }

    private static func key(_ name: String) -> String { "switch.battery." + name }
    private func save(_ value: Any, _ name: String) { UserDefaults.standard.set(value, forKey: Self.key(name)) }
    private func saveJSON<T: Encodable>(_ value: T, _ name: String) {
        do { save(try JSONEncoder().encode(value), name) } catch { NSLog("win-tab: can't save \(name): \(error)") }
    }
}

enum BatteryEvent: Equatable {
    case low(level: Int)
    case charged(level: Int)
    case pluggedIn
    case unplugged
    case accessoryLow(name: String)
}

/// When to alert. Each alert fires once when its condition becomes true and re-arms once it's
/// clearly false again, so a battery hovering at a level doesn't nag.
struct BatteryAlertRules {
    struct Settings {
        var low: [Int]
        var charged: [Int]
        var plug: Bool
        var unplug: Bool
        var accessory: Int?
    }

    struct Snapshot: Equatable {
        var percent: Int
        var pluggedIn: Bool
        var accessories: [String: Int] = [:]
    }

    /// Percent a level must be cleared by before it can fire again.
    private static let rearm = 2
    private static let accessoryRearm = 5

    private(set) var fired: Set<String> = []
    private var last: Snapshot?

    mutating func step(_ now: Snapshot, _ s: Settings) -> [BatteryEvent] {
        var events: [BatteryEvent] = []
        let first = last == nil
        defer { last = now }

        if let last, last.pluggedIn != now.pluggedIn {
            if now.pluggedIn && s.plug { events.append(.pluggedIn) }
            if !now.pluggedIn && s.unplug { events.append(.unplugged) }
        }

        // Low: only the lowest level reached fires; the ones above it count as fired too.
        for level in s.low where now.pluggedIn || now.percent > level + Self.rearm { fired.remove("low\(level)") }
        if !now.pluggedIn {
            let reached = s.low.filter { now.percent <= $0 && !fired.contains("low\($0)") }
            if let lowest = reached.min() {
                events.append(.low(level: lowest))
                reached.forEach { fired.insert("low\($0)") }
            }
        }

        // Charged: only the highest level reached fires; already there at launch doesn't count.
        for level in s.charged where !now.pluggedIn || now.percent < level - Self.rearm { fired.remove("charged\(level)") }
        if now.pluggedIn {
            let reached = s.charged.filter { now.percent >= $0 && !fired.contains("charged\($0)") }
            if let highest = reached.max() {
                if !first { events.append(.charged(level: highest)) }
                reached.forEach { fired.insert("charged\($0)") }
            }
        }

        if let level = s.accessory {
            for (name, percent) in now.accessories.sorted(by: { $0.key < $1.key }) {
                let key = "acc:" + name
                if percent > level + Self.accessoryRearm { fired.remove(key) }
                if percent <= level && !fired.contains(key) {
                    fired.insert(key)
                    events.append(.accessoryLow(name: name))
                }
            }
        }
        return events
    }

    #if DEBUG
    /// Walks the rules through a discharge and a charge; returns failures.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        let s = Settings(low: [20, 10, 5], charged: [80, 100], plug: true, unplug: true, accessory: 20)
        var r = BatteryAlertRules()
        func expect(_ snap: Snapshot, _ want: [BatteryEvent], _ label: String) {
            let got = r.step(snap, s)
            if got != want { failures.append("battery rules, \(label): got \(got), want \(want)") }
        }
        expect(Snapshot(percent: 85, pluggedIn: true), [], "plugged at 85 on launch is quiet")
        expect(Snapshot(percent: 85, pluggedIn: false), [.unplugged], "unplug")
        expect(Snapshot(percent: 21, pluggedIn: false), [], "above 20")
        expect(Snapshot(percent: 20, pluggedIn: false), [.low(level: 20)], "reach 20")
        expect(Snapshot(percent: 19, pluggedIn: false), [], "no repeat at 19")
        expect(Snapshot(percent: 21, pluggedIn: false), [], "hovering back to 21 doesn't re-arm")
        expect(Snapshot(percent: 20, pluggedIn: false), [], "no nag at 20 again")
        expect(Snapshot(percent: 4, pluggedIn: false), [.low(level: 5)], "jump to 4 fires only 5")
        expect(Snapshot(percent: 4, pluggedIn: true), [.pluggedIn], "plug in")
        expect(Snapshot(percent: 80, pluggedIn: true), [.charged(level: 80)], "charged to 80")
        expect(Snapshot(percent: 81, pluggedIn: true), [], "no repeat at 81")
        expect(Snapshot(percent: 100, pluggedIn: true), [.charged(level: 100)], "charged to 100")
        expect(Snapshot(percent: 18, pluggedIn: false), [.unplugged, .low(level: 20)], "unplugged low re-arms")
        expect(Snapshot(percent: 50, pluggedIn: false, accessories: ["AirPods": 15]), [.accessoryLow(name: "AirPods")], "accessory low")
        expect(Snapshot(percent: 50, pluggedIn: false, accessories: ["AirPods": 12]), [], "accessory once")

        var atLaunch = BatteryAlertRules()
        if atLaunch.step(Snapshot(percent: 8, pluggedIn: false), s) != [.low(level: 10)] {
            failures.append("battery rules: launch at 8% should warn once, at 10")
        }
        return failures
    }
    #endif
}

/// One alert, drawn by the notch or the bubble.
struct NotchAlert: Equatable, Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String
    let color: Color
    /// A word or two for the compact notch alert: "Low", "Charging".
    var short = ""
    /// Figure beside the notch, e.g. "20%".
    let badge: String
    /// 0…1 fill of the level bar and the bubble's ring; nil hides them.
    var level: Double?
    /// An app's bundle id: its icon stands in for the gauge (notifications from other apps).
    var appIcon: String?
    /// Overrides Settings → Battery's notch alert style (notifications have their own).
    var style: BatteryPreferences.NotchAlertStyle?
    /// Shrinks away as soon as the pointer comes near, so it never sits over your work.
    var dodges = false

    static func == (a: NotchAlert, b: NotchAlert) -> Bool { a.id == b.id }
}

/// Turns battery changes into alerts and shows them: notch or bubble, sound, screen glow.
@MainActor
final class BatteryAlertCenter {
    static let shared = BatteryAlertCenter()
    private var rules = BatteryAlertRules()
    private var prefs: BatteryPreferences { .shared }
    private lazy var bubble = AlertBubble()

    private init() {}

    func start() {
        BatteryMonitor.shared.onChange.append { [weak self] in self?.evaluate() }
        evaluate()
    }

    private func evaluate() {
        let monitor = BatteryMonitor.shared
        guard let b = monitor.state else { return }
        let snap = BatteryAlertRules.Snapshot(percent: b.percent, pluggedIn: b.pluggedIn,
                                              accessories: Dictionary(monitor.accessories.map { ($0.name, $0.percent) }, uniquingKeysWith: min))
        // Several at once (unplugged and low): the most urgent wins.
        guard let event = rules.step(snap, prefs.rules).min(by: { Self.urgency($0) < Self.urgency($1) }) else { return }
        present(event)
    }

    private static func urgency(_ e: BatteryEvent) -> Int {
        switch e {
        case .low: return 0
        case .accessoryLow: return 1
        case .charged: return 2
        case .unplugged, .pluggedIn: return 3
        }
    }

    /// Also used by Settings → Battery → Preview. `style` overrides the event's own.
    func present(_ event: BatteryEvent, style override: AlertStyle? = nil) {
        show(Self.alert(for: event), style: override ?? prefs.style(for: event))
    }

    static func alert(for event: BatteryEvent) -> NotchAlert {
        let b = BatteryMonitor.shared.state
        let percent = b?.percent ?? 0
        let level = Double(percent) / 100
        switch event {
        case .low:
            return NotchAlert(symbol: percent <= 10 ? "battery.0percent" : "battery.25percent", title: "\(percent)% Remaining",
                              detail: b?.minutesToEmpty.map { "\(BatteryDetails.duration($0)) until empty" } ?? "Plug in soon",
                              color: percent <= 10 ? .red : .orange, short: "Low Battery", badge: "\(percent)%", level: level)
        case .charged(let target):
            return NotchAlert(symbol: target >= 100 ? "battery.100percent" : "battery.100percent.bolt",
                              title: target >= 100 ? "Fully Charged" : "Charged to \(percent)%",
                              detail: target >= 100 ? "You can unplug now" : "Unplug to protect battery health",
                              color: .green, short: "Charged", badge: "\(percent)%", level: level)
        case .pluggedIn:
            return NotchAlert(symbol: "bolt.fill", title: b?.charging == false ? "Plugged In" : "Charging",
                              detail: [b?.adapterWatts.map { "\($0) W adapter" }, b?.timeLabel].compactMap { $0 }.joined(separator: " · "),
                              color: .green, short: b?.charging == false ? "Plugged In" : "Charging", badge: "\(percent)%", level: level)
        case .unplugged:
            return NotchAlert(symbol: "powerplug.fill", title: "On Battery", detail: b?.timeLabel ?? "",
                              color: Color(red: 0.45, green: 0.75, blue: 1), short: "On Battery", badge: "\(percent)%", level: level)
        case .accessoryLow(let name):
            let device = BatteryMonitor.shared.accessories.first { $0.name == name }
            let p = device?.percent ?? 0
            return NotchAlert(symbol: device?.symbol ?? "headphones", title: "\(name) \(p)%", detail: device?.parts ?? "Charge it soon",
                              color: .orange, short: name, badge: "\(p)%", level: Double(p) / 100)
        }
    }

    /// A notification as a bubble (Glass card, Pill, Vivid) under the menu bar.
    func showBubble(_ alert: NotchAlert, theme: BatteryPreferences.BubbleTheme, duration: TimeInterval) {
        bubble.show(alert, at: .top, duration: duration, size: prefs.bubbleSize, theme: theme)
    }

    private func show(_ alert: NotchAlert, style: AlertStyle) {
        if style.sound != "None" { NSSound(named: style.sound)?.play() }
        if style.glow { ScreenGlow.shared.flash(NSColor(alert.color), strength: prefs.glowStrength) }
        let duration: TimeInterval? = style.persistent ? nil : prefs.alertDuration
        if style.position == .notch, NotchController.current?.present(alert, duration: duration) == true { return }
        bubble.show(alert, at: style.position == .center ? .center : .top, duration: duration, size: prefs.bubbleSize, theme: prefs.bubbleTheme)
    }
}

/// The alert bubble (Glass, Minimal or Vivid), in the centre of the screen or under the menu bar.
/// Persistent alerts stay until their close button.
@MainActor
private final class AlertBubble {
    enum Placement { case center, top }
    private let panel: NSPanel
    private var generation = 0

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    func show(_ alert: NotchAlert, at placement: Placement, duration: TimeInterval?, size: BatteryPreferences.BubbleSize,
              theme: BatteryPreferences.BubbleTheme) {
        // Settings → Notch → Alerts show on (all at once → the main display: one bubble is enough).
        guard let screen = SwitchPreferences.shared.alertScreens.first ?? NSScreen.main else { return }
        // Room around the capsule for its shadow and ring glow.
        let pad: CGFloat = 30
        let base = AlertBubbleView.size(theme)
        let s = CGSize(width: base.width * size.scale + pad * 2, height: base.height * size.scale + pad * 2)
        let v = screen.visibleFrame
        let y = placement == .center ? v.midY - s.height / 2 + v.height * 0.12 : v.maxY - s.height + pad - 6
        panel.setFrame(CGRect(x: v.midX - s.width / 2, y: y, width: s.width, height: s.height), display: false)
        generation += 1
        let mine = generation
        let view = AlertBubbleView(alert: alert, theme: theme, scale: size.scale, closable: duration == nil) { [weak self] in self?.dismiss(mine) }
        let host = NSHostingView(rootView: view.padding(pad))
        host.wantsLayer = true
        panel.contentView = host
        panel.orderFrontRegardless()
        if let layer = host.layer {
            // Scale about the centre.
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: host.frame.midX, y: host.frame.midY)
            // Drops in from a little above while growing, like a notification sliding down.
            let pop = CASpringAnimation(keyPath: "transform")
            pop.fromValue = CATransform3DScale(CATransform3DMakeTranslation(0, 26, 0), 0.86, 0.86, 1)
            pop.toValue = CATransform3DIdentity
            pop.stiffness = 300
            pop.damping = 22
            pop.duration = pop.settlingDuration
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            layer.add(pop, forKey: "pop")
            layer.add(fade, forKey: "fade")
        }
        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.dismiss(mine) }
        }
    }

    private func dismiss(_ generation: Int) {
        guard generation == self.generation, let layer = panel.contentView?.layer else { return }
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.94
        let group = CAAnimationGroup()
        group.animations = [out, shrink]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.add(group, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, generation == self.generation else { return }
            self.panel.orderOut(nil)
        }
    }
}

/// A soft glow around every display's edges, faded in and out on the render server.
@MainActor
final class ScreenGlow {
    static let shared = ScreenGlow()
    private static let duration: CFTimeInterval = 2.2
    private var panels: [NSPanel] = []
    private var generation = 0

    func flash(_ color: NSColor, strength: BatteryPreferences.GlowStrength) {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let host = NSHostingView(rootView: GlowEdge(color: Color(nsColor: color), strength: strength))
            host.wantsLayer = true
            p.contentView = host
            p.setFrame(screen.frame, display: true)
            p.orderFrontRegardless()
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0, 1, 1, 0]
            a.keyTimes = [0, 0.15, 0.55, 1]
            a.duration = Self.duration
            host.layer?.opacity = 0
            host.layer?.add(a, forKey: "glow")
            return p
        }
        generation += 1
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.panels.forEach { $0.orderOut(nil) }
            self.panels = []
        }
    }
}

/// The glow's drawing; the Settings preview uses it too.
struct GlowEdge: View {
    let color: Color
    var strength: BatteryPreferences.GlowStrength = .standard

    var body: some View {
        let k: CGFloat = strength == .subtle ? 0.6 : strength == .strong ? 1.6 : 1
        ZStack {
            Rectangle().strokeBorder(color, lineWidth: 14 * k).blur(radius: 30 * k)
            Rectangle().strokeBorder(color.opacity(0.75), lineWidth: 4 * k).blur(radius: 6 * k)
        }
        .opacity(strength == .subtle ? 0.7 : 1)
        .ignoresSafeArea()
    }
}
