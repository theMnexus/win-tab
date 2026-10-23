import AppKit
import SwiftUI

/// Colour for a charge level: green when charging or above half, yellow down to 21%, red below.
enum BatteryPalette {
    static func color(percent: Int, charging: Bool) -> Color {
        if charging { return .green }
        if percent <= 20 { return .red }
        if percent <= 50 { return .yellow }
        return .green
    }
}

/// iPhone-style battery: a rounded body filled to the level with the percentage cut out of it.
struct BatteryGlyph: View {
    let percent: Int
    var charging = false
    /// Nil draws in the foreground colour (template look).
    var color: Color?
    var showsPercent = true
    var height: CGFloat = 12

    var body: some View {
        let width = height * 2.15, radius = height * 0.32
        let tint = color ?? .primary
        HStack(spacing: height * 0.08) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(0.32))
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint)
                    .frame(width: max(radius, width * CGFloat(min(max(percent, 0), 100)) / 100))
                if showsPercent {
                    Text("\(percent)")
                        .font(.system(size: height * 0.72, weight: .bold, design: .rounded)).monospacedDigit()
                        .frame(width: width)
                        .blendMode(.destinationOut)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .compositingGroup()
            Capsule().fill(tint.opacity(0.4)).frame(width: height * 0.14, height: height * 0.38)
            if charging {
                Image(systemName: "bolt.fill").font(.system(size: height * 0.72, weight: .bold)).foregroundStyle(tint)
            }
        }
    }
}

/// Big battery, percentage and what it's doing; top of the Battery tab, the popover and the notch.
struct BatteryHero: View {
    let battery: BatteryDetails
    var compact = false

    var body: some View {
        let color = BatteryPalette.color(percent: battery.percent, charging: battery.charging)
        HStack(spacing: compact ? 14 : 22) {
            BatteryGlyph(percent: battery.percent, charging: battery.charging, color: color, showsPercent: false, height: compact ? 24 : 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(battery.percent)").font(.system(size: compact ? 28 : 46, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: compact ? 15 : 22, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                Text(statusLine).font(.system(size: compact ? 11 : 13, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let health = battery.health {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Health").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text("\(health)%").font(.system(size: compact ? 18 : 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(health < 80 ? .orange : .primary)
                    if let condition = battery.condition, !compact {
                        Text(condition).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var statusLine: String {
        if battery.pluggedIn && battery.fullyCharged { return "Fully charged" }
        let source = battery.pluggedIn ? (battery.charging ? "Charging" : "Power adapter") : "On battery"
        return "\(source) · \(battery.timeLabel)"
    }
}

/// One figure in the stats grid.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String = ""
    var level: Double?
    var tint: Color = .accentColor
    /// Every tile the same height so the grid reads as rows.
    static let height: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.6)
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let level {
                GeometryReader { g in
                    Capsule().fill(Color.primary.opacity(0.1))
                        .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: g.size.width * min(max(level, 0), 1)) }
                }
                .frame(height: 4)
            }
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .frame(height: Self.height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

/// Health, cycles, power and the rest, as a grid of tiles.
struct BatteryStatsGrid: View {
    let battery: BatteryDetails
    var columns = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columns), spacing: 10) {
            if let health = battery.health {
                StatTile(title: "Maximum capacity", value: "\(health)%", detail: "Against when it was new", level: Double(health) / 100,
                         tint: health < 80 ? .orange : .green)
            }
            if let cycles = battery.cycles {
                StatTile(title: "Cycle count", value: "\(cycles)", detail: "Most Mac batteries are rated for 1000")
            }
            if let watts = battery.watts {
                StatTile(title: battery.pluggedIn ? "Charging power" : "Power draw", value: String(format: "%.1f W", watts),
                         detail: battery.amperage.map { String(format: "%.2f A", abs($0)) } ?? "")
            }
            if let full = battery.fullCapacity {
                StatTile(title: "Charge", value: "\(battery.remainingCapacity ?? 0) / \(full) mAh",
                         detail: battery.designCapacity.map { "\($0) mAh when new" } ?? "")
            }
            if let v = battery.voltage {
                StatTile(title: "Voltage", value: String(format: "%.2f V", v))
            }
            if let t = battery.temperature {
                StatTile(title: "Temperature", value: String(format: "%.1f °C", t), detail: t > 40 ? "Warm: let it cool" : "")
            }
            if let w = battery.adapterWatts, battery.pluggedIn {
                StatTile(title: "Adapter", value: "\(w) W")
            }
        }
    }
}

/// Accessories, lowest first.
struct AccessoryBatteryList: View {
    let accessories: [AccessoryBattery]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(accessories.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Divider().opacity(0.4).padding(.leading, 50) }
                HStack(spacing: 12) {
                    Image(systemName: device.symbol).font(.system(size: 16)).frame(width: 24).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if let parts = device.parts { Text(parts).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    BatteryGlyph(percent: device.percent, color: BatteryPalette.color(percent: device.percent, charging: false), height: 13)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }
}
