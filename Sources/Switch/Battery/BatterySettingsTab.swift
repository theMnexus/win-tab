import AppKit
import SwiftUI

/// Settings → Battery, laid out like Juicy: a sidebar of pages on the left.
struct BatterySettingsTab: View {
    enum Page: String, CaseIterable, Identifiable {
        case general, alerts, menuBar, devices, battery, appUsage
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "General"
            case .alerts: return "Alerts"
            case .menuBar: return "Menu Bar"
            case .devices: return "Devices"
            case .battery: return "Battery"
            case .appUsage: return "App Usage"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .alerts: return "bell.fill"
            case .menuBar: return "menubar.rectangle"
            case .devices: return "ipad.and.iphone"
            case .battery: return "minus.plus.batteryblock.fill"
            case .appUsage: return "square.stack.3d.up.fill"
            }
        }
        var color: Color {
            switch self {
            case .general: return Color(red: 0.55, green: 0.8, blue: 0.3)
            case .alerts: return Color(red: 0.3, green: 0.75, blue: 0.4)
            case .menuBar: return Color(red: 0.3, green: 0.72, blue: 0.55)
            case .devices: return Color(red: 0.3, green: 0.65, blue: 0.85)
            case .battery: return Color(red: 0.3, green: 0.5, blue: 0.95)
            case .appUsage: return Color(red: 0.25, green: 0.6, blue: 0.95)
            }
        }
        /// Sidebar heading above this page, if it starts a group.
        var group: String? { self == .battery ? "Insights" : nil }
    }

    @AppStorage("switch.battery.settingsPage") private var page: Page = .general
    @ObservedObject private var monitor = BatteryMonitor.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    PageIcon(page: page, size: 30)
                    Text(page.label).font(.system(size: 20, weight: .semibold))
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
                Divider().opacity(0.5)
                ScrollView {
                    Group {
                        switch page {
                        case .general: BatteryGeneralPage()
                        case .alerts: BatteryAlertsPage()
                        case .menuBar: BatteryMenuBarPage()
                        case .devices: BatteryDevicesPage()
                        case .battery: BatteryInsightsPage()
                        case .appUsage: AppUsagePage()
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(page)
            }
        }
        .onAppear { monitor.refresh(accessories: true) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Page.allCases) { p in
                if let group = p.group {
                    Text(group).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 2)
                }
                SidebarRow(page: p, selected: p == page) { page = p }
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 176)
        .background(Color.primary.opacity(0.025))
    }
}

private struct PageIcon: View {
    let page: BatterySettingsTab.Page
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(page.color.gradient))
    }
}

private struct SidebarRow: View {
    let page: BatterySettingsTab.Page
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PageIcon(page: page)
                Text(page.label).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.1) : hovering ? Color.primary.opacity(0.05) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(selected ? 0.08 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Heading with an icon, like Juicy's section titles.
struct BatterySectionTitle: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title).font(.system(size: 16, weight: .semibold))
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            if !subtitle.isEmpty {
                Label(subtitle, systemImage: "info.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - General

private struct BatteryGeneralPage: View {
    @ObservedObject private var prefs = BatteryPreferences.shared
    @State private var showGlow = false

    private var sample: NotchAlert {
        NotchAlert(symbol: "battery.25percent", title: "15% Remaining", detail: "9m until empty", color: .orange,
                   short: "Low Battery", badge: "15%", level: 0.15)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BatterySectionTitle(title: "Alert Bubble", symbol: "sparkles", tint: .purple,
                                subtitle: "For alerts set to Center of Screen, and for notch alerts when the notch island is off")
            ThemePicker(selection: $prefs.bubbleTheme, sample: sample)
            SettingsCard {
                SettingsRow(title: "Size") {
                    Picker("", selection: $prefs.bubbleSize) {
                        ForEach(BatteryPreferences.BubbleSize.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                SettingsDivider()
                SettingsRow(title: "Screen edge glow", detail: "Turn it on or off per alert in Alerts.") {
                    Picker("", selection: $prefs.glowStrength) {
                        ForEach(BatteryPreferences.GlowStrength.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                SettingsDivider()
                SettingsSlider(title: "Stays for", value: "\(Int(prefs.alertDuration)) s, unless the alert is persistent", number: $prefs.alertDuration,
                               range: BatteryPreferences.alertDurationRange, step: 1)
                SettingsDivider()
                VStack(spacing: 12) {
                    HStack {
                        Text("Preview").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Show glow", isOn: $showGlow).toggleStyle(.switch).controlSize(.small)
                    }
                    ZStack {
                        SampleDesktop()
                        if showGlow { GlowEdge(color: .orange, strength: prefs.glowStrength) }
                        AlertBubbleView(alert: sample, theme: prefs.bubbleTheme, scale: prefs.bubbleSize.scale * 0.92)
                            .id("\(prefs.bubbleTheme)\(prefs.bubbleSize)")
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: prefs.bubbleTheme)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: prefs.bubbleSize)
                    Button {
                        let first = prefs.lowAlerts.first
                        var style = first?.style ?? AlertStyle()
                        style.position = .center
                        BatteryAlertCenter.shared.present(.low(level: first?.level ?? 20), style: style)
                    } label: {
                        Label("Show on Screen", systemImage: "play.fill")
                    }
                    .controlSize(.large)
                }
                .padding(16)
            }

            BatterySectionTitle(title: "Notch Alerts", symbol: "rectangle.topthird.inset.filled", tint: .blue)
            SettingsCard {
                SettingsSegmented(title: "Style", detail: "Compact keeps it to the wings beside the notch, like the iPhone's; Icon is just the gauge and the figure.",
                                  selection: $prefs.notchAlertStyle, options: BatteryPreferences.NotchAlertStyle.allCases, label: \.label, width: 260)
                SettingsDivider()
                VStack(spacing: 12) {
                    ZStack(alignment: .top) {
                        SampleDesktop()
                        NotchAlertPreview(alert: sample, style: prefs.notchAlertStyle)
                            .id(prefs.notchAlertStyle)
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                    }
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: prefs.notchAlertStyle)
                    Button {
                        let first = prefs.lowAlerts.first
                        var style = first?.style ?? AlertStyle()
                        style.position = .notch
                        BatteryAlertCenter.shared.present(.low(level: first?.level ?? 20), style: style)
                    } label: {
                        Label("Show on the Notch", systemImage: "play.fill")
                    }
                    .controlSize(.large)
                }
                .padding(16)
            }
        }
    }
}

/// Three cards to pick the bubble's look, each drawing it.
private struct ThemePicker: View {
    @Binding var selection: BatteryPreferences.BubbleTheme
    let sample: NotchAlert
    @ObservedObject private var app = SwitchPreferences.shared

    var body: some View {
        HStack(spacing: 10) {
            ForEach(BatteryPreferences.BubbleTheme.allCases) { theme in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = theme } } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            SampleDesktop()
                            AlertBubbleView(alert: sample, theme: theme, scale: 0.42, closable: false)
                        }
                        .frame(height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(theme.label).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selection == theme ? app.accent.color : .secondary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(selection == theme ? 0.08 : 0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(selection == theme ? app.accent.color : Color.primary.opacity(0.08), lineWidth: selection == theme ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A soft, colourful stand-in for a desktop, so glass has something to show through.
struct SampleDesktop: View {
    var body: some View {
        // Blobs in an overlay, sized to the space given, so they never widen the layout.
        LinearGradient(colors: [Color(red: 0.12, green: 0.1, blue: 0.3), Color(red: 0.05, green: 0.2, blue: 0.3)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                GeometryReader { g in
                    Circle().fill(Color(red: 0.95, green: 0.45, blue: 0.3).opacity(0.55))
                        .frame(width: g.size.height * 0.9).blur(radius: g.size.height * 0.22)
                        .position(x: g.size.width * 0.3, y: g.size.height * 0.62)
                    Circle().fill(Color(red: 0.3, green: 0.6, blue: 1).opacity(0.5))
                        .frame(width: g.size.height).blur(radius: g.size.height * 0.26)
                        .position(x: g.size.width * 0.75, y: g.size.height * 0.35)
                }
            }
            .clipped()
    }
}

// MARK: - Alerts

private struct BatteryAlertsPage: View {
    @ObservedObject private var prefs = BatteryPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Configure battery notifications and visual effects").font(.system(size: 12)).foregroundStyle(.secondary)
            BatterySectionTitle(title: "General", symbol: "gearshape")
            SettingsCard {
                SettingsToggle(title: "Enable notifications", detail: "Show battery alerts and notifications.", isOn: $prefs.alertsEnabled)
            }
            if prefs.alertsEnabled {
                BatterySectionTitle(title: "Low Battery Alerts", symbol: "battery.25percent", tint: .red, subtitle: "Notify when battery goes below percentage")
                ForEach($prefs.lowAlerts) { $alert in
                    LevelAlertRow(alert: $alert, charged: false) { prefs.lowAlerts.removeAll { $0.id == alert.id } }
                }
                AddLevelButton(title: "Add Low Battery Alert", charged: false)

                BatterySectionTitle(title: "Charged Alerts", symbol: "battery.100percent.bolt", tint: .green, subtitle: "Notify when battery reaches percentage")
                ForEach($prefs.chargedAlerts) { $alert in
                    LevelAlertRow(alert: $alert, charged: true) { prefs.chargedAlerts.removeAll { $0.id == alert.id } }
                }
                AddLevelButton(title: "Add Charged Alert", charged: true)

                BatterySectionTitle(title: "Power Source Alerts", symbol: "powerplug.fill", tint: .orange, subtitle: "Notify when the adapter is connected or removed")
                ToggleAlertRow(title: "Plugged In", symbol: "bolt.fill", tint: .green, event: .pluggedIn, isOn: $prefs.plugAlert, style: $prefs.plugStyle)
                ToggleAlertRow(title: "Unplugged", symbol: "powerplug.fill", tint: .blue, event: .unplugged, isOn: $prefs.unplugAlert, style: $prefs.unplugStyle)

                BatterySectionTitle(title: "Device Alerts", symbol: "airpodspro", tint: .cyan, subtitle: "AirPods, Magic Mouse, Keyboard and Trackpad")
                ToggleAlertRow(title: "Below \(prefs.accessoryLevel)%", symbol: "headphones", tint: .orange, event: nil,
                               isOn: $prefs.accessoryAlert, style: $prefs.accessoryStyle, level: $prefs.accessoryLevel)
            }
        }
    }

}

/// A percentage you can type or step, with the % sign after it.
private struct LevelField: View {
    @Binding var value: Int
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .frame(width: 58)
                .onSubmit(onSubmit)
            Text("%").foregroundStyle(.secondary)
            Stepper("", value: $value, in: BatteryPreferences.levelRange).labelsHidden()
        }
    }
}

/// "Add … Alert": opens a popover to type any level, with a few common ones to tap.
private struct AddLevelButton: View {
    let title: String
    let charged: Bool
    @ObservedObject private var prefs = BatteryPreferences.shared
    @State private var open = false
    @State private var level = 15
    @State private var problem: String?

    private var suggestions: [Int] { charged ? [70, 80, 90, 100] : [30, 20, 15, 10, 5, 3] }

    var body: some View {
        HStack {
            Spacer()
            Button {
                let taken = Set((charged ? prefs.chargedAlerts : prefs.lowAlerts).map(\.level))
                level = suggestions.first { !taken.contains($0) } ?? (charged ? 85 : 25)
                problem = nil
                open = true
            } label: { Label(title, systemImage: "plus") }
            .controlSize(.large)
            .popover(isPresented: $open, arrowEdge: .bottom) { editor }
            Spacer()
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(charged ? "Alert when the battery reaches" : "Alert when the battery drops to").font(.system(size: 13, weight: .semibold))
            HStack {
                LevelField(value: $level, onSubmit: add)
                Spacer()
                Button("Add", action: add).keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { l in
                    Button("\(l)%") { level = l }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled((charged ? prefs.chargedAlerts : prefs.lowAlerts).contains { $0.level == l })
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onChange(of: level) { _, _ in problem = nil }
    }

    private func add() {
        problem = prefs.addAlert(level: level, charged: charged)
        if problem == nil { open = false }
    }
}

/// A card for one level alert: icon, level, how it shows, edit and delete.
private struct LevelAlertRow: View {
    @Binding var alert: LevelAlert
    let charged: Bool
    let remove: () -> Void
    @State private var editing = false

    var body: some View {
        let tint: Color = charged ? .green : alert.level <= 5 ? .red : .orange
        AlertCard {
            BatteryGlyph(percent: charged ? alert.level : max(alert.level, 12), color: tint, showsPercent: false, height: 13)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(alert.level)%").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.18)))
                Text(alert.style.summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } actions: {
            CircleButton(symbol: "gearshape.fill") { editing = true }
                .popover(isPresented: $editing, arrowEdge: .trailing) {
                    AlertStyleEditor(style: $alert.style, level: Binding(get: { alert.level }, set: { new in
                        BatteryPreferences.shared.setLevel(new, of: alert.id, charged: charged)
                    }), event: charged ? .charged(level: alert.level) : .low(level: alert.level))
                }
            CircleButton(symbol: "trash.fill", tint: .red, action: remove)
        }
    }
}

/// A card for an on/off alert (plugged in, unplugged, devices) with its style.
private struct ToggleAlertRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let event: BatteryEvent?
    @Binding var isOn: Bool
    @Binding var style: AlertStyle
    var level: Binding<Int>?
    @State private var editing = false
    @ObservedObject private var prefs = SwitchPreferences.shared

    var body: some View {
        AlertCard {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(style.summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } actions: {
            CircleButton(symbol: "gearshape.fill") { editing = true }
                .popover(isPresented: $editing, arrowEdge: .trailing) {
                    AlertStyleEditor(style: $style, level: level, event: event)
                }
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(prefs.accent.color)
        }
        .opacity(isOn ? 1 : 0.6)
    }
}

private struct AlertCard<Leading: View, Actions: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 14) {
            leading
            Spacer(minLength: 8)
            HStack(spacing: 10) { actions }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

private struct CircleButton: View {
    let symbol: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(hovering ? 0.22 : 0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Popover for one alert: level, where it shows, glow, persistent, sound, and a preview.
private struct AlertStyleEditor: View {
    @Binding var style: AlertStyle
    var level: Binding<Int>?
    let event: BatteryEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let level {
                HStack {
                    Text("Level")
                    Spacer()
                    LevelField(value: level)
                }
            }
            Picker("Show", selection: $style.position) {
                ForEach(AlertStyle.Position.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Border glow", isOn: $style.glow)
            Toggle("Persistent (stays until you close it)", isOn: $style.persistent)
            HStack {
                Picker("Sound", selection: $style.sound) {
                    ForEach(BatteryPreferences.sounds, id: \.self) { Text($0).tag($0) }
                }
                Button { NSSound(named: style.sound)?.play() } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).disabled(style.sound == "None")
            }
            if let event {
                Button("Preview") { BatteryAlertCenter.shared.present(Self.preview(event, level: level?.wrappedValue), style: style) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .toggleStyle(.switch)
        .padding(16)
        .frame(width: 320)
    }

    /// The event at the level being edited.
    private static func preview(_ event: BatteryEvent, level: Int?) -> BatteryEvent {
        switch event {
        case .low: return .low(level: level ?? 20)
        case .charged: return .charged(level: level ?? 80)
        default: return event
        }
    }
}

// MARK: - Menu bar

private struct BatteryMenuBarPage: View {
    @ObservedObject private var prefs = BatteryPreferences.shared
    @ObservedObject private var monitor = BatteryMonitor.shared

    var body: some View {
        let p = monitor.state?.percent ?? 80, c = monitor.state?.charging ?? false
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                SettingsToggle(title: "Battery in the menu bar", detail: "An iPhone-style battery with the percentage inside; click it for details. Hide the macOS one in System Settings → Control Centre.",
                               isOn: $prefs.menuBarIcon)
                SettingsDivider()
                SettingsSegmented(title: "Style", detail: "Colour: green, yellow below 50%, red below 20%.", selection: $prefs.menuBarStyle,
                                  options: BatteryPreferences.MenuBarStyle.allCases, label: \.label, width: 170)
                SettingsToggle(title: "Percentage inside", isOn: $prefs.menuBarPercent)
            }
            HStack(spacing: 28) {
                Spacer()
                ForEach(Array([p, 64, 35, 12].enumerated()), id: \.offset) { i, level in
                    BatteryGlyph(percent: level, charging: i == 0 && c,
                                 color: prefs.menuBarStyle == .colour ? BatteryPalette.color(percent: level, charging: i == 0 && c) : nil,
                                 showsPercent: prefs.menuBarPercent, height: 15)
                }
                Spacer()
            }
            .padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }
}

// MARK: - Devices

private struct BatteryDevicesPage: View {
    @ObservedObject private var monitor = BatteryMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BatterySectionTitle(title: "This Mac", symbol: "laptopcomputer")
            SettingsCard {
                if let b = monitor.state {
                    BatteryHero(battery: b).padding(18)
                } else {
                    Text("No internal battery.").foregroundStyle(.secondary).padding(16)
                }
            }
            BatterySectionTitle(title: "Connected Devices", symbol: "dot.radiowaves.left.and.right", subtitle: "Lowest battery first")
            SettingsCard {
                if monitor.accessories.isEmpty {
                    Text("None connected right now. AirPods show up while they're connected to this Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } else {
                    AccessoryBatteryList(accessories: monitor.accessories)
                }
            }
            HStack {
                Spacer()
                Button("Refresh") { monitor.refresh(accessories: true) }.controlSize(.small)
            }
        }
    }
}
