import AppKit
import Charts
import SwiftUI

/// Pill buttons for a time range (24h / 7d / 14d …).
private struct RangePills<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var tint: Color = .green

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { value, label in
                Button { withAnimation(.easeOut(duration: 0.2)) { selection = value } } label: {
                    Text(label).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == value ? .white : .secondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(selection == value ? tint : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct InsightCard<Content: View>: View {
    var tint: Color?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint?.opacity(0.08) ?? Color(nsColor: .controlBackgroundColor).opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke((tint ?? .primary).opacity(tint == nil ? 0.07 : 0.3), lineWidth: 1))
    }
}

private struct TintedIconLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.foregroundStyle(tint); configuration.title }
    }
}

private struct FigureTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let note: String
    var noteTint: Color = .green

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title.uppercased(), systemImage: symbol).font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary).labelStyle(TintedIconLabel(tint: tint))
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.system(size: 12, weight: .semibold)).foregroundStyle(noteTint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - Battery

/// Settings → Battery → Battery: health, temperature and cycles, level over time, daily energy.
struct BatteryInsightsPage: View {
    enum LevelRange: Int { case day = 1, week = 7, twoWeeks = 14 }
    enum UsageRange: Int { case week = 7, month = 30, quarter = 90 }

    @ObservedObject private var monitor = BatteryMonitor.shared
    @ObservedObject private var history = BatteryHistory.shared
    @State private var levelRange: LevelRange = .day
    @State private var usageRange: UsageRange = .week

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Daily usage, health, cycle and temperature trends for your Mac over time").font(.system(size: 12)).foregroundStyle(.secondary)
            if let b = monitor.state {
                HStack(spacing: 12) {
                    FigureTile(title: "Health", symbol: "heart.fill", tint: .green, value: b.health.map { "\($0)%" } ?? "–",
                               note: b.healthVerdict, noteTint: b.serviceRecommended ? .orange : .green)
                    FigureTile(title: "Temperature", symbol: "thermometer.medium", tint: .green,
                               value: b.temperature.map { String(format: "%.1f°C", $0) } ?? "–",
                               note: b.temperatureVerdict ?? "Not reported", noteTint: b.temperatureVerdict == "Normal" ? .green : .orange)
                    FigureTile(title: "Cycles", symbol: "arrow.triangle.2.circlepath", tint: .blue, value: b.cycles.map(String.init) ?? "–",
                               note: "of 1000 rated", noteTint: .blue)
                }
            }
            levelCard
            usageCard
            if let b = monitor.state {
                BatterySectionTitle(title: "Details", symbol: "info.circle")
                BatteryStatsGrid(battery: b)
            }
        }
    }

    /// "just now", "37s ago", "4m ago", "2h ago".
    static func ago(_ date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSinceNow))
        if s < 10 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        return s < 3600 ? "\(s / 60)m ago" : "\(s / 3600)h ago"
    }

    private var levelCard: some View {
        InsightCard {
            HStack {
                Label("Battery Level", systemImage: "battery.100percent").font(.system(size: 15, weight: .semibold)).labelStyle(TintedIconLabel(tint: .green))
                Spacer()
                RangePills(options: [(LevelRange.day, "24h"), (.week, "7d"), (.twoWeeks, "14d")], selection: $levelRange)
            }
            if let last = history.lastCharge {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last charged to \(last.percent)%").font(.system(size: 17, weight: .semibold))
                    Text(last.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            BatteryLevelChart(samples: history.samples(since: Date().addingTimeInterval(-Double(levelRange.rawValue) * 86400)), days: levelRange.rawValue)
                .frame(height: 190)
            Label("Battery charge over the last \(levelRange == .day ? "24 hours" : "\(levelRange.rawValue) days"). Shaded green windows are when your Mac was charging.",
                  systemImage: "info.circle")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private var usageCard: some View {
        let days = history.dailyEnergy(days: usageRange.rawValue)
        let total = days.reduce(0) { $0 + $1.total }
        return InsightCard {
            HStack {
                Label("DAILY USAGE", systemImage: "chart.bar.fill").font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(.secondary).labelStyle(TintedIconLabel(tint: .green))
                if let at = history.latestAt {
                    Label("Collected \(Self.ago(at))", systemImage: "circle.fill")
                        .font(.system(size: 11.5, weight: .medium)).labelStyle(TintedIconLabel(tint: .green))
                }
                Spacer()
                RangePills(options: [(UsageRange.week, "7d"), (.month, "30d"), (.quarter, "90d")], selection: $usageRange, tint: .indigo)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Energy Usage").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(String(format: "%.0f total", total)).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            Chart(days, id: \.day) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Energy", d.total))
                    .foregroundStyle(Color.green.gradient)
                    .cornerRadius(4)
            }
            .chartYAxis { AxisMarks(position: .trailing) }
            .frame(height: 160)
            Text("Energy impact of the apps that ran each day, as Activity Monitor measures it; sampled every 5 minutes while win-tab runs.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

/// Bars of the charge level over time, red at 20% and below, with charging stretches shaded.
private struct BatteryLevelChart: View {
    let samples: [BatteryHistory.Sample]
    let days: Int

    private struct Bin: Identifiable {
        let id: Int
        let start: Date
        let percent: Int
        let plugged: Bool
    }

    private var binSeconds: TimeInterval { days == 1 ? 900 : days == 7 ? 7200 : 14400 }
    private var windowStart: Date { Date().addingTimeInterval(-Double(days) * 86400) }

    /// The last sample in each bin.
    private var bins: [Bin] {
        let start = windowStart.timeIntervalSince1970
        var latest: [Int: BatteryHistory.Sample] = [:]
        for s in samples { latest[Int((s.t - start) / binSeconds)] = s }
        return latest.sorted { $0.key < $1.key }.map { i, s in
            Bin(id: i, start: Date(timeIntervalSince1970: start + Double(i) * binSeconds), percent: s.p, plugged: s.a)
        }
    }

    /// Runs of neighbouring plugged-in bins, as time ranges.
    private func chargingWindows(_ bins: [Bin]) -> [(Date, Date)] {
        var windows: [(Date, Date)] = []
        var run: (Date, Date)?
        var lastID: Int?
        for bin in bins {
            let end = bin.start.addingTimeInterval(binSeconds)
            if bin.plugged, let r = run, lastID == bin.id - 1 {
                run = (r.0, end)
            } else {
                if let r = run { windows.append(r) }
                run = bin.plugged ? (bin.start, end) : nil
            }
            lastID = bin.id
        }
        if let r = run { windows.append(r) }
        return windows
    }

    var body: some View {
        let bins = self.bins
        if bins.isEmpty {
            Text("Collecting… the chart fills in as win-tab records your battery every few minutes.")
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let windows = chargingWindows(bins)
            Chart {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, w in
                    RectangleMark(xStart: .value("From", w.0), xEnd: .value("To", w.1), yStart: .value("Low", 0), yEnd: .value("High", 100))
                        .foregroundStyle(Color.green.opacity(0.12))
                    RuleMark(xStart: .value("From", w.0), xEnd: .value("To", w.1), y: .value("Base", -5))
                        .foregroundStyle(Color.green).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                ForEach(bins) { bin in
                    BarMark(x: .value("Time", bin.start), yStart: .value("Zero", 0), yEnd: .value("Level", bin.percent), width: .fixed(days == 1 ? 3 : 4))
                        .foregroundStyle(bin.percent <= 20 ? Color.red : Color.green)
                        .cornerRadius(1.5)
                }
                RuleMark(y: .value("Half", 50)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartYScale(domain: -9...100)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }
                }
            }
            .chartXScale(domain: windowStart...Date())
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: days == 1 ? 8 : 7)) { _ in
                    AxisValueLabel(format: days == 1 ? .dateTime.hour() : .dateTime.weekday(.abbreviated))
                }
            }
        }
    }
}

// MARK: - App usage

/// Settings → Battery → App Usage: what's using energy now, over time, and anything unusual.
struct AppUsagePage: View {
    enum Range: Int { case day = 1, week = 7, month = 30 }
    @ObservedObject private var history = BatteryHistory.shared
    @State private var range: Range = .day
    @State private var focused: String?

    private var since: Date { Date().addingTimeInterval(-Double(range.rawValue) * 86400) }
    private var rangeLabel: String { range == .day ? "24h" : "\(range.rawValue)d" }

    var body: some View {
        let totals = history.appTotals(since: since)
        let grand = max(totals.reduce(0) { $0 + $1.total }, 0.0001)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(history.daysCollected) \(history.daysCollected == 1 ? "day" : "days") of history collected · \(totals.count) apps tracked in the last \(rangeLabel)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                RangePills(options: [(Range.day, "24h"), (.week, "7d"), (.month, "30d")], selection: $range, tint: .indigo)
            }
            HStack(alignment: .top, spacing: 12) {
                rightNow
                drainers(totals, grand: grand)
            }
            if let unusual = history.unusual { insight(unusual.app, factor: unusual.factor) }
            BatterySectionTitle(title: "TOP ENERGY CONSUMERS", symbol: "list.bullet.rectangle")
            InsightCard {
                if totals.isEmpty {
                    Text("Collecting… win-tab samples energy use every 5 minutes; the list fills in within the hour.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(Array(totals.prefix(12).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().opacity(0.4) }
                    consumerRow(entry.id, share: entry.total / grand)
                }
            }
        }
        .onAppear { if history.latest.isEmpty { history.measure(force: true) } }
    }

    private func insight(_ app: AppEnergy, factor: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BatterySectionTitle(title: "INSIGHTS", symbol: "sparkles", tint: .yellow)
            InsightCard(tint: .orange) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            AppIcon(path: app.path, size: 18)
                            Text("\(app.name) is unusually active right now").font(.system(size: 14, weight: .semibold))
                        }
                        Text(String(format: "It's drawing about %.1f× more energy than its typical share. It may be stuck in a loop or doing background work. Restart it if you're not actively using it.", factor))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button { focused = app.id } label: { Label("See details", systemImage: "chart.bar.fill") }
                            Button {
                                NSRunningApplication.runningApplications(withBundleIdentifier: app.id).forEach { $0.terminate() }
                            } label: { Label("Quit", systemImage: "xmark.circle") }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var rightNow: some View {
        let total = max(history.latest.reduce(0) { $0 + $1.impact }, 0.0001)
        return InsightCard {
            HStack {
                Label("RIGHT NOW", systemImage: "bolt.circle").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                if history.measuring {
                    ProgressView().controlSize(.mini)
                } else if let at = history.latestAt {
                    Text(BatteryInsightsPage.ago(at)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if history.latest.isEmpty {
                Text("Measuring…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(history.latest.prefix(5).enumerated()), id: \.element.id) { i, app in
                RankRow(rank: i + 1, path: app.path, name: app.name, share: app.impact / total, tint: .cyan,
                        trailing: EnergyShare.format(app.impact / total), sub: nil)
            }
            Button("Measure again") { history.measure(force: true) }.controlSize(.small).disabled(history.measuring)
        }
    }

    private func drainers(_ totals: [(id: String, total: Double)], grand: Double) -> some View {
        let onBattery = history.secondsOnBattery(since: since)
        return InsightCard(tint: .orange) {
            Label("TOP DRAINERS · \(rangeLabel.uppercased())", systemImage: "flame.fill").font(.system(size: 11, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.orange)
            if totals.isEmpty {
                Text("Collecting…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(totals.prefix(5).enumerated()), id: \.element.id) { i, entry in
                let share = entry.total / grand
                let info = history.apps[entry.id]
                // Time on battery that went to this app, estimated by its share of the energy.
                RankRow(rank: i + 1, path: info?.path ?? "", name: info?.name ?? entry.id, share: share, tint: .pink,
                        trailing: onBattery > 60 ? "~" + BatteryDetails.duration(max(1, Int(onBattery * share / 60))) : EnergyShare.format(share),
                        sub: onBattery > 60 ? EnergyShare.format(share) : nil)
            }
        }
    }

    private func consumerRow(_ id: String, share: Double) -> some View {
        let info = history.apps[id]
        let series = history.series(id, since: since, stepHours: range == .day ? 1 : range == .week ? 4 : 12)
        return HStack(spacing: 12) {
            AppIcon(path: info?.path ?? "", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(info?.name ?? id).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(id).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Chart(Array(series.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("t", i), y: .value("e", v)).foregroundStyle(Color.red.opacity(0.18))
                LineMark(x: .value("t", i), y: .value("e", v)).foregroundStyle(Color.red).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(width: 150, height: 34)
            VStack(alignment: .trailing, spacing: 0) {
                Text(EnergyShare.format(share)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("of total").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .frame(width: 58, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(focused == id ? Color.orange.opacity(0.12) : .clear))
    }
}

private struct AppIcon: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Group {
            if path.isEmpty {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            }
        }
        .frame(width: size, height: size)
    }
}

private struct RankRow: View {
    let rank: Int
    let path: String
    let name: String
    let share: Double
    let tint: Color
    let trailing: String
    let sub: String?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 12)
            AppIcon(path: path, size: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                GeometryReader { g in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: max(3, g.size.width * min(share, 1))) }
                }
                .frame(height: 3)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(trailing).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                if let sub { Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            }
            .frame(width: 64, alignment: .trailing)
        }
    }
}
