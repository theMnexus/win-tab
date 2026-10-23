import AppKit
import SwiftUI

/// Floating glass bar under the open island with a button per tab, like Droppy's.
struct NotchTabBar: View {
    @ObservedObject var state: NotchState
    @ObservedObject private var prefs = SwitchPreferences.shared
    @ObservedObject private var nowPlaying = NowPlayingMonitor.shared
    @Namespace private var selection

    private var tint: Color { nowPlaying.tint ?? prefs.accent.color }

    var body: some View {
        let tabs = NotchTab.enabled
        let current = tabs.contains(state.tab) ? state.tab : .home
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                NotchTabBarButton(tab: tab, selected: tab == current, tint: tint, selection: selection) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { state.tab = tab }
                }
            }
        }
        .padding(4)
        .background {
            if #available(macOS 26.0, *) {
                Color.clear
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .liquidGlass(true, cornerRadius: (NotchGeometry.tabBarHeight - 4) / 2, tint: tint.opacity(0.22))
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .frame(height: NotchGeometry.tabBarHeight - 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

private struct NotchTabBarButton: View {
    let tab: NotchTab
    let selected: Bool
    let tint: Color
    let selection: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? .white : .white.opacity(hovering ? 0.95 : 0.7))
                .frame(width: 46, height: NotchGeometry.tabBarHeight - 12)
                .background {
                    if selected {
                        Capsule().fill(tint.opacity(0.45)).matchedGeometryEffect(id: "selected", in: selection)
                    } else if hovering {
                        Capsule().fill(.white.opacity(0.1))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering && !selected ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .help(tab.label)
    }
}

/// The notch's Battery tab: the battery on the left, detail pages on the right.
struct NotchBatteryView: View {
    enum Page: String, CaseIterable, Identifiable {
        case health, power, capacity, apps, devices
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @ObservedObject private var monitor = BatteryMonitor.shared
    @ObservedObject private var history = BatteryHistory.shared
    @AppStorage("switch.notch.batteryPage") private var page: Page = .health

    var body: some View {
        if let b = monitor.state {
            HStack(alignment: .top, spacing: 14) {
                NotchBatterySummary(battery: b).frame(width: 176)
                VStack(alignment: .leading, spacing: 8) {
                    pagePicker
                    Group {
                        switch page {
                        case .health: NotchHealthPage(battery: b)
                        case .power: NotchPowerPage(battery: b)
                        case .capacity: NotchCapacityPage(battery: b)
                        case .apps: NotchAppsPage(apps: history.latest, measuring: history.measuring)
                        case .devices: NotchDevicesPage(devices: monitor.accessories)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                }
            }
            .onAppear {
                if page == .apps && history.latest.isEmpty { history.measure(force: true) }
            }
        } else {
            Text("This Mac has no internal battery.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var pagePicker: some View {
        HStack(spacing: 4) {
            ForEach(Page.allCases) { p in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { page = p }
                    if p == .apps && history.latest.isEmpty { history.measure(force: true) }
                    if p == .devices { monitor.refresh(accessories: true) }
                } label: {
                    Text(p.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(page == p ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(page == p ? Color.white.opacity(0.9) : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Big percentage, source, level bar, time left and Low Power Mode.
private struct NotchBatterySummary: View {
    let battery: BatteryDetails
    @ObservedObject private var monitor = BatteryMonitor.shared

    var body: some View {
        let color = BatteryPalette.color(percent: battery.percent, charging: battery.charging)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(battery.percent)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(color)
                Text("%").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(color.opacity(0.8))
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(battery.pluggedIn ? "TO FULL" : "TIME LEFT").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    Text(timeValue).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            HStack(spacing: 6) {
                BatteryGlyph(percent: battery.percent, charging: battery.charging, color: color, showsPercent: false, height: 10)
                Text(source).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            LevelBar(percent: battery.percent, color: color)
            Button { monitor.setLowPowerMode(!battery.lowPowerMode) } label: {
                Label("Low Power", systemImage: "leaf.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(battery.lowPowerMode ? .black : .yellow)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(battery.lowPowerMode ? Color.yellow : Color.yellow.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .help(battery.lowPowerMode ? "Turn Low Power Mode off" : "Turn Low Power Mode on (asks for your password)")
        }
    }

    private var source: String {
        battery.pluggedIn ? (battery.fullyCharged ? "Charged" : battery.charging ? "Charging" : "Not charging") : "On Battery"
    }

    private var timeValue: String {
        if battery.pluggedIn && battery.fullyCharged { return "Full" }
        let minutes = battery.pluggedIn ? battery.minutesToFull : battery.minutesToEmpty
        return minutes.map(BatteryDetails.duration) ?? "…"
    }
}

/// Level bar with ticks at 20, 50 and 80%.
private struct LevelBar: View {
    let percent: Int
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(color).frame(width: max(6, g.size.width * CGFloat(percent) / 100))
                ForEach([0.2, 0.5, 0.8], id: \.self) { t in
                    Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: g.size.height + 4).offset(x: g.size.width * t)
                }
            }
        }
        .frame(height: 6)
    }
}

private struct NotchFigure: View {
    let title: String
    let value: String
    var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(.white.opacity(0.45))
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if !note.isEmpty { Text(note).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotchHealthPage: View {
    let battery: BatteryDetails

    var body: some View {
        let tint: Color = battery.serviceRecommended ? .orange : .green
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Battery Health", systemImage: battery.serviceRecommended ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(battery.health.map { "\($0)%" } ?? "–").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                    Text(battery.healthVerdict).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 0)
                    if let cycles = battery.cycles {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(cycles)/1000").font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text("Cycles").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                LevelBar(percent: battery.health ?? 0, color: tint)
            }
            VStack(alignment: .leading, spacing: 5) {
                Label("Temperature", systemImage: "thermometer.medium").font(.system(size: 11, weight: .semibold)).foregroundStyle(temperatureTint)
                if let t = battery.temperature {
                    Text(String(format: "%.1f°C", t)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(temperatureTint)
                    Text(String(format: "%.1f°F · %@", t * 9 / 5 + 32, battery.temperatureVerdict ?? ""))
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                } else {
                    Text("Not reported").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 130, alignment: .leading)
        }
    }

    private var temperatureTint: Color {
        switch battery.temperatureVerdict {
        case "Hot": return .red
        case "Warm": return .orange
        default: return .green
        }
    }
}

private struct NotchPowerPage: View {
    let battery: BatteryDetails
    @Environment(\.notchOpen) private var open

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                NotchFigure(title: battery.pluggedIn ? "Charging" : "Power use", value: battery.watts.map { String(format: "%.1f W", $0) } ?? "–")
                NotchFigure(title: "Voltage", value: battery.voltage.map { String(format: "%.2f V", $0) } ?? "–")
                NotchFigure(title: "Current", value: battery.amperage.map { "\(Int(abs($0) * 1000)) mA" } ?? "–",
                            note: (battery.amperage ?? 0) < 0 ? "Discharging" : "Charging")
            }
            flow
        }
    }

    /// Where the power goes: battery → Mac, or adapter → Mac and battery.
    private var flow: some View {
        HStack(spacing: 6) {
            flowEnd(battery.pluggedIn ? "powerplug.fill" : "battery.75percent")
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !open)) { ctx in
                let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07))
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.35)
                            .offset(x: g.size.width * (phase * 1.35 - 0.35))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(battery.watts.map { String(format: "%.1f W", $0) } ?? "–").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            flowEnd(battery.pluggedIn && battery.charging ? "laptopcomputer.and.arrow.down" : "laptopcomputer")
        }
        .frame(height: 30)
    }

    private func flowEnd(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
            .frame(width: 40, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07)))
    }
}

private struct NotchCapacityPage: View {
    let battery: BatteryDetails
    @ObservedObject private var monitor = BatteryMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Remaining", battery.remainingCapacity, .green)
            row("Current full", battery.fullCapacity, Color(red: 0.4, green: 0.7, blue: 1))
            row("Design capacity", battery.designCapacity, .white.opacity(0.7))
            Button { monitor.refresh(accessories: true) } label: {
                Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ title: String, _ value: Int?, _ tint: Color) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value.map { "\($0) mAh" } ?? "–").font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
        }
    }
}

private struct NotchAppsPage: View {
    let apps: [AppEnergy]
    let measuring: Bool

    var body: some View {
        let total = max(apps.reduce(0) { $0 + $1.impact }, 1)
        if apps.isEmpty {
            HStack(spacing: 6) {
                if measuring { ProgressView().controlSize(.mini) }
                Text(measuring ? "Measuring…" : "Nothing measured yet.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(apps.prefix(4)) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 15, height: 15)
                        Text(app.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).frame(width: 120, alignment: .leading)
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.08))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(app.impact / total > 0.5 ? Color.orange : Color.cyan).frame(width: g.size.width * app.impact / total)
                                }
                        }
                        .frame(height: 4)
                        Text(EnergyShare.format(app.impact / total)).font(.system(size: 11, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7)).frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
    }
}

enum EnergyShare {
    static func format(_ share: Double) -> String {
        share >= 0.1 ? String(format: "%.0f%%", share * 100) : String(format: "%.1f%%", share * 100)
    }
}

private struct NotchDevicesPage: View {
    let devices: [AccessoryBattery]

    var body: some View {
        if devices.isEmpty {
            Text("No Bluetooth accessories reporting a battery right now.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(devices.prefix(4)) { d in
                    HStack(spacing: 8) {
                        Image(systemName: d.symbol).font(.system(size: 12)).frame(width: 16).foregroundStyle(.white.opacity(0.7))
                        Text(d.name).font(.system(size: 11.5)).lineLimit(1)
                        if let parts = d.parts { Text(parts).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                        Spacer(minLength: 4)
                        BatteryGlyph(percent: d.percent, color: BatteryPalette.color(percent: d.percent, charging: false), height: 11)
                    }
                }
            }
        }
    }
}
