import AppKit
import Darwin

/// One app's energy impact in one `top` sample, summed over its helper processes.
struct AppEnergy: Codable, Identifiable, Equatable {
    /// Bundle id, or the bundle path when there's none.
    let id: String
    let name: String
    let path: String
    var impact: Double
    var pid: Int32
}

enum AppEnergyReader {
    /// ponytail: two one-second `top` samples (~2 s, off the main thread) every few minutes.
    nonisolated static func read() -> [AppEnergy] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "2", "-s", "1", "-n", "120", "-o", "power", "-stats", "pid,power"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { NSLog("win-tab: top failed: \(error)"); return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return group(parse(String(decoding: data, as: UTF8.self)))
    }

    /// (pid, impact) rows after the last header; the first sample has no energy figures yet.
    nonisolated static func parse(_ text: String) -> [(Int32, Double)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [] }
        return lines[(header + 1)...].compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, let pid = Int32(cols[0]), let impact = Double(cols[cols.count - 1]), impact > 0 else { return nil }
            return (pid, impact)
        }
    }

    /// Adds helpers into the app that ships them (Chrome's helpers into Chrome); processes that
    /// aren't part of an app are left out, like Juicy does.
    nonisolated static func group(_ rows: [(Int32, Double)]) -> [AppEnergy] {
        var apps: [String: AppEnergy] = [:]
        for (pid, impact) in rows {
            guard let bundle = appBundle(pid) else { continue }
            let (id, name) = identity(bundle)
            if var app = apps[id] {
                app.impact += impact
                apps[id] = app
            } else {
                apps[id] = AppEnergy(id: id, name: name, path: bundle, impact: impact, pid: pid)
            }
        }
        return apps.values.sorted { $0.impact > $1.impact }
    }

    /// Bundle id and display name per bundle path; reading an Info.plist every sample adds up.
    /// Only touched from the one sampling task at a time (`BatteryHistory.measuring`).
    private nonisolated(unsafe) static var identities: [String: (String, String)] = [:]

    nonisolated static func identity(_ bundle: String) -> (id: String, name: String) {
        if let known = identities[bundle] { return known }
        let found = (Bundle(path: bundle)?.bundleIdentifier ?? bundle,
                     (FileManager.default.displayName(atPath: bundle) as NSString).deletingPathExtension)
        identities[bundle] = found
        return found
    }

    /// The outermost `.app` in the process's executable path.
    nonisolated static func appBundle(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return outermostApp(String(cString: buffer))
    }

    nonisolated static func outermostApp(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

/// Battery level and per-app energy over time, kept on disk for the Battery and App Usage pages.
@MainActor
final class BatteryHistory: ObservableObject {
    static let shared = BatteryHistory()

    struct Sample: Codable, Equatable {
        let t: TimeInterval
        let p: Int
        /// Charging, plugged in.
        let c: Bool
        let a: Bool
    }

    struct Bucket: Codable {
        /// Start of the hour.
        let hour: TimeInterval
        var samples: Int
        var apps: [String: Double]
    }

    struct AppInfo: Codable { let name: String; let path: String }

    private struct File: Codable {
        var battery: [Sample] = []
        var energy: [Bucket] = []
        var apps: [String: AppInfo] = [:]
    }

    private static let keepDays = 90.0
    private static let batteryEvery: TimeInterval = 300
    private static let energyEvery: TimeInterval = 300
    /// A gap longer than this between samples means the Mac was asleep or off.
    static let maxGap: TimeInterval = 900

    @Published private(set) var battery: [Sample] = []
    @Published private(set) var energy: [Bucket] = []
    @Published private(set) var apps: [String: AppInfo] = [:]
    /// The latest `top` sample, for "Right now".
    @Published private(set) var latest: [AppEnergy] = []
    @Published private(set) var latestAt: Date?
    @Published private(set) var measuring = false

    private var timer: Timer?
    private var dirty = false

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("win-tab", isDirectory: true)
        return dir.appendingPathComponent("battery-history.json")
    }

    private init() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            battery = file.battery
            energy = file.energy
            apps = file.apps
        } catch {
            NSLog("win-tab: battery history unreadable, starting fresh: \(error)")
        }
    }

    func start() {
        BatteryMonitor.shared.onChange.append { [weak self] in self?.recordBattery() }
        recordBattery()
        timer = Timer.scheduledTimer(withTimeInterval: Self.energyEvery, repeats: true) { _ in
            MainActor.assumeIsolated {
                BatteryHistory.shared.recordBattery(force: true)
                BatteryHistory.shared.measure()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MainActor.assumeIsolated { BatteryHistory.shared.measure() } }
        importSystemLog()
    }

    /// Fills in the time before win-tab started recording from macOS's own power log (a charge
    /// reading at every sleep and wake), so the level chart isn't empty on day one.
    /// Once: the log is tens of MB and takes seconds to print, and the history keeps what it
    /// brought in. Lines without a charge reading are dropped by grep before they reach us.
    private func importSystemLog() {
        guard !UserDefaults.standard.bool(forKey: Self.importedLogKey) else { return }
        let before = battery.first?.t ?? Date().timeIntervalSince1970
        DispatchQueue.global(qos: .utility).async {
            let pmset = Process(), grep = Process()
            pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            pmset.arguments = ["-g", "log"]
            grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            grep.arguments = ["-F", "(Charge:"]
            let link = Pipe(), out = Pipe()
            pmset.standardOutput = link
            pmset.standardError = FileHandle.nullDevice
            grep.standardInput = link
            grep.standardOutput = out
            do {
                try grep.run()
                try pmset.run()
            } catch {
                NSLog("win-tab: pmset log failed: \(error)")
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            pmset.waitUntilExit()
            grep.waitUntilExit()
            guard pmset.terminationStatus == 0 else { return }
            let older = Self.parsePowerLog(String(decoding: data, as: UTF8.self)).filter { $0.t < before - 60 }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    UserDefaults.standard.set(true, forKey: Self.importedLogKey)
                    guard !older.isEmpty else { return }
                    let history = BatteryHistory.shared
                    history.battery = (older + history.battery).sorted { $0.t < $1.t }
                    history.dirty = true
                    history.save()
                }
            }
        }
    }

    private static let importedLogKey = "switch.battery.importedSystemLog"

    /// "2026-09-28 21:09:56 +0700 Sleep … Using Batt (Charge:84%) …" → samples.
    nonisolated static func parsePowerLog(_ text: String) -> [Sample] {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return text.split(separator: "\n").compactMap { line in
            guard line.count > 25, let charge = line.range(of: "(Charge:"), let date = format.date(from: String(line.prefix(25))) else { return nil }
            let digits = line[charge.upperBound...].prefix { $0 == " " || $0.isNumber }.filter(\.isNumber)
            guard let percent = Int(digits) else { return nil }
            let onAC = line.range(of: "Using AC", options: .caseInsensitive) != nil
            return Sample(t: date.timeIntervalSince1970, p: percent, c: onAC && percent < 100, a: onAC)
        }
    }

    /// Adds a battery sample when something changed or it's been a while.
    func recordBattery(force: Bool = false) {
        guard let b = BatteryMonitor.shared.state else { return }
        let now = Date().timeIntervalSince1970
        let sample = Sample(t: now, p: b.percent, c: b.charging, a: b.pluggedIn)
        if let last = battery.last {
            let changed = last.p != sample.p || last.c != sample.c || last.a != sample.a
            guard (changed && now - last.t > 30) || now - last.t >= Self.batteryEvery || (force && now - last.t > 60) else { return }
        }
        battery.append(sample)
        dirty = true
    }

    /// Takes a `top` sample and adds it to this hour's bucket. The timer's samples skip while
    /// nobody's at the Mac; a view asking (`force`) always gets one.
    func measure(force: Bool = false) {
        guard !measuring, force || !SystemActivity.userAway else { return }
        measuring = true
        DispatchQueue.global(qos: .utility).async {
            let found = AppEnergyReader.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { BatteryHistory.shared.add(found) } }
        }
    }

    private func add(_ found: [AppEnergy]) {
        measuring = false
        latest = found
        latestAt = Date()
        guard !found.isEmpty else { return }
        let hour = (Date().timeIntervalSince1970 / 3600).rounded(.down) * 3600
        if energy.last?.hour != hour { energy.append(Bucket(hour: hour, samples: 0, apps: [:])) }
        var bucket = energy.removeLast()
        bucket.samples += 1
        for app in found {
            bucket.apps[app.id, default: 0] += app.impact
            if apps[app.id] == nil { apps[app.id] = AppInfo(name: app.name, path: app.path) }
        }
        energy.append(bucket)
        dirty = true
        if Date().timeIntervalSince(lastSave) > Self.saveEvery { save() }
    }

    /// The file is rewritten whole, so at most this often (and at quit).
    private static let saveEvery: TimeInterval = 1800
    private var lastSave = Date()

    func save() {
        guard dirty else { return }
        let cutoff = Date().timeIntervalSince1970 - Self.keepDays * 86400
        battery.removeAll { $0.t < cutoff }
        energy.removeAll { $0.hour < cutoff }
        let file = File(battery: battery, energy: energy, apps: apps)
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: Self.url, options: .atomic)
            dirty = false
            lastSave = Date()
        } catch {
            NSLog("win-tab: battery history save failed: \(error)")
        }
    }

    // MARK: - Queries

    func samples(since: Date) -> [Sample] { battery.filter { $0.t >= since.timeIntervalSince1970 } }

    /// Days since the first sample.
    var daysCollected: Int {
        guard let first = battery.first?.t ?? energy.first?.hour else { return 0 }
        return max(1, Int((Date().timeIntervalSince1970 - first) / 86400) + 1)
    }

    /// The highest level of the most recent stretch on the adapter, and when it got there.
    var lastCharge: (percent: Int, date: Date)? {
        guard let end = battery.lastIndex(where: { $0.a }) else { return nil }
        var start = end
        while start > 0, battery[start - 1].a { start -= 1 }
        guard let top = battery[start...end].max(by: { $0.p < $1.p }) else { return nil }
        return (top.p, Date(timeIntervalSince1970: top.t))
    }

    /// Seconds spent on battery in the window (gaps longer than `maxGap` are sleep).
    func secondsOnBattery(since: Date) -> TimeInterval {
        let s = samples(since: since)
        return zip(s, s.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.t - pair.0.t
            return total + (!pair.0.a && gap <= Self.maxGap ? gap : 0)
        }
    }

    /// Each app's average energy impact per sample, summed over the hours in the window.
    func appTotals(since: Date) -> [(id: String, total: Double)] {
        var totals: [String: Double] = [:]
        for b in energy where b.hour >= since.timeIntervalSince1970 && b.samples > 0 {
            for (id, impact) in b.apps { totals[id, default: 0] += impact / Double(b.samples) }
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.total > $1.total }
    }

    /// Apps seen in the window.
    func appCount(since: Date) -> Int { appTotals(since: since).count }

    /// An app's energy per `stepHours` hours over the window, oldest first, for a sparkline.
    func series(_ id: String, since: Date, stepHours: Int) -> [Double] {
        let start = (since.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        let count = max(1, Int((Date().timeIntervalSince1970 - start) / 3600 / Double(stepHours)) + 1)
        var values = [Double](repeating: 0, count: count)
        for b in energy where b.hour >= start && b.samples > 0 {
            let i = min(count - 1, Int((b.hour - start) / 3600) / stepHours)
            values[i] += (b.apps[id] ?? 0) / Double(b.samples)
        }
        return values
    }

    /// Total energy per day, oldest first, for the Daily Usage chart.
    func dailyEnergy(days: Int) -> [(day: Date, total: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: today) ?? today
            let from = day.timeIntervalSince1970, to = from + 86400
            let total = energy.filter { $0.hour >= from && $0.hour < to && $0.samples > 0 }
                .reduce(0) { $0 + $1.apps.values.reduce(0, +) / Double($1.samples) }
            return (day, total)
        }
    }

    /// An app drawing far more than its usual share right now, with how many times more.
    var unusual: (app: AppEnergy, factor: Double)? {
        let total = latest.reduce(0) { $0 + $1.impact }
        guard total > 0, let top = latest.first, top.impact >= 10 else { return nil }
        let nowShare = top.impact / total
        let week = appTotals(since: Date().addingTimeInterval(-7 * 86400))
        let weekTotal = week.reduce(0) { $0 + $1.total }
        guard weekTotal > 0, let usual = week.first(where: { $0.id == top.id }).map({ $0.total / weekTotal }), usual > 0 else { return nil }
        let factor = nowShare / usual
        return factor >= 3 && nowShare >= 0.3 ? (top, factor) : nil
    }

    #if DEBUG
    static func selfCheck() -> [String] {
        var failures: [String] = []
        let bundle = "/Applications/Google Chrome.app"
        if AppEnergyReader.outermostApp(bundle + "/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Helper") != bundle {
            failures.append("history: helper not folded into its app")
        }
        if AppEnergyReader.outermostApp("/usr/libexec/trustd") != nil { failures.append("history: daemon counted as an app") }
        let rows = AppEnergyReader.parse("PID POWER\n1 0.0\nPID POWER\n12 40.8\n13 0.0\n14 3.5\n")
        if rows.map(\.0) != [12, 14] { failures.append("history: top parse \(rows)") }
        let log = parsePowerLog("2026-09-28 21:09:56 +0700 Sleep  \tEntering Sleep Using Batt (Charge:84%) 31 secs\n"
                                + "2026-09-28 22:00:00 +0700 Wake  \tWake Using AC (Charge: 100%)\nnoise line without charge\n")
        if log.map(\.p) != [84, 100] || log.map(\.a) != [false, true] { failures.append("history: power log parse \(log)") }
        return failures
    }
    #endif
}
