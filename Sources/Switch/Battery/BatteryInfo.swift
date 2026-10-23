import AppKit
import IOKit
import IOKit.ps

/// Everything the Mac reports about its internal battery. Optional fields are missing on some
/// models (Intel Macs don't report temperature, for one).
struct BatteryDetails: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var fullyCharged: Bool
    /// Minutes left on battery / to full; nil while macOS is still estimating.
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var cycles: Int?
    /// mAh: what the battery held new, what it holds full now, what's in it now.
    var designCapacity: Int?
    var fullCapacity: Int?
    var remainingCapacity: Int?
    /// Volts and amps; amps are negative while discharging.
    var voltage: Double?
    var amperage: Double?
    var temperature: Double?
    var adapterWatts: Int?
    /// macOS's own verdict: "Good", "Fair", "Poor", "Check Battery"…
    var condition: String?
    var lowPowerMode = false

    /// Full-charge capacity against design capacity, rounded down like System Settings' "Maximum Capacity".
    var health: Int? {
        guard let design = designCapacity, design > 0, let full = fullCapacity, full > 0 else { return nil }
        return min(100, full * 100 / design)
    }

    /// Power flowing out of (or into) the battery.
    var watts: Double? {
        guard let v = voltage, let a = amperage, a != 0 else { return nil }
        return abs(v * a)
    }

    /// "Good" at 80% and up, like Apple's own threshold for service.
    var healthVerdict: String {
        guard let health else { return condition ?? "Unknown" }
        return health >= 80 ? "Good" : health >= 70 ? "Fair" : "Service"
    }

    /// Battery temperature in words: under 35 °C is where Apple wants it.
    var temperatureVerdict: String? {
        guard let t = temperature else { return nil }
        return t < 35 ? "Normal" : t < 40 ? "Warm" : "Hot"
    }

    var serviceRecommended: Bool {
        (health ?? 100) < 80 || condition.map { !["Good", "Normal"].contains($0) } ?? false
    }

    /// "2h 05m left", "1h 10m to full", "Charged", "Not charging" or "Estimating…".
    var timeLabel: String {
        if fullyCharged && pluggedIn { return "Charged" }
        if pluggedIn {
            guard charging else { return "Not charging" }
            return minutesToFull.map { "\(Self.duration($0)) to full" } ?? "Estimating…"
        }
        return minutesToEmpty.map { "\(Self.duration($0)) left" } ?? "Estimating…"
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? String(format: "%dh %02dm", minutes / 60, minutes % 60) : "\(minutes)m"
    }
}

enum BatteryReader {
    /// Internal battery details, nil on Macs without one.
    static func read() -> BatteryDetails? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let minutes = { (key: String) -> Int? in (d[key] as? Int).flatMap { $0 > 0 ? $0 : nil } }
            var b = BatteryDetails(
                percent: current * 100 / max,
                charging: (d[kIOPSIsChargingKey] as? Bool) ?? false,
                pluggedIn: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                fullyCharged: (d[kIOPSIsChargedKey] as? Bool) ?? false,
                minutesToEmpty: minutes(kIOPSTimeToEmptyKey),
                minutesToFull: minutes(kIOPSTimeToFullChargeKey),
                condition: d[kIOPSBatteryHealthKey] as? String)
            addSmartBattery(to: &b)
            b.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            if b.pluggedIn, let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
                b.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
            }
            return b
        }
        return nil
    }

    /// Cycle count, capacities, voltage, current and temperature from the battery controller.
    private static func addSmartBattery(to b: inout BatteryDetails) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let top = props?.takeRetainedValue() as? [String: Any] else { return }
        // Some models keep the capacities only in the nested BatteryData.
        let nested = top["BatteryData"] as? [String: Any] ?? [:]
        let d = top.merging(nested) { mine, _ in mine }
        let int = { (key: String) -> Int? in (d[key] as? NSNumber)?.intValue }
        b.cycles = int("CycleCount")
        b.designCapacity = int("DesignCapacity").flatMap { $0 > 0 ? $0 : nil }
        // Apple Silicon reports mAh in AppleRaw*; Intel in NominalChargeCapacity.
        b.fullCapacity = [int("NominalChargeCapacity"), int("AppleRawMaxCapacity"), int("FullChargeCapacity")].compactMap { $0 }.first { $0 > 100 }
        b.remainingCapacity = [int("AppleRawCurrentCapacity"), int("RemainingCapacity")].compactMap { $0 }.first { $0 > 0 }
            ?? b.fullCapacity.map { $0 * b.percent / 100 }
        b.voltage = int("Voltage").map { Double($0) / 1000 }
        // Stored unsigned; the wrap-around is the negative (discharging) current.
        b.amperage = (d["Amperage"] as? NSNumber).map { Double($0.int64Value) / 1000 }
        b.temperature = [int("Temperature"), int("VirtualTemperature")].compactMap { $0 }.first { $0 > 0 }.map { Double($0) / 100 }
            ?? SMC.cachedBatteryTemperature()
    }
}

/// A Bluetooth accessory's battery: Magic Mouse/Keyboard/Trackpad, AirPods (left, right, case).
struct AccessoryBattery: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let symbol: String
    /// The lowest part (an AirPod, not the case) for sorting and alerts.
    let percent: Int
    /// "L 80% · R 75% · Case 40%" for devices with parts.
    var parts: String?
}

enum AccessoryReader {
    /// Magic accessories report through IOKit; cheap enough to read on every refresh.
    static func readHID() -> [AccessoryBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [AccessoryBattery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let prop = { (key: String) in IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let percent = (prop("BatteryPercent") as? NSNumber)?.intValue, let name = prop("Product") as? String,
                  !found.contains(where: { $0.name == name }) else { continue }
            found.append(AccessoryBattery(name: name, symbol: symbol(for: name, kind: ""), percent: percent))
        }
        return found
    }

    /// AirPods and other headphones only show up in System Information's Bluetooth report.
    /// ponytail: shells out to system_profiler (~0.5 s); called every few minutes off the main thread.
    nonisolated static func readBluetooth() -> [AccessoryBattery] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { NSLog("win-tab: system_profiler failed: \(error)"); return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseBluetooth(data)
    }

    nonisolated static func parseBluetooth(_ data: Data) -> [AccessoryBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var found: [AccessoryBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let d = value as? [String: Any] else { continue }
                    let level = { (key: String) -> Int? in (d[key] as? String).flatMap { Int($0.filter(\.isNumber)) } }
                    let parts = [("L", level("device_batteryLevelLeft")), ("R", level("device_batteryLevelRight")),
                                 ("Case", level("device_batteryLevelCase"))].compactMap { label, v in v.map { (label, $0) } }
                    let main = level("device_batteryLevelMain") ?? level("device_batteryLevel")
                    // The case often reads 0 while the buds are out of it; don't let it drive alerts.
                    let buds = parts.filter { $0.0 != "Case" }.map(\.1)
                    guard let lowest = buds.min() ?? main ?? parts.first?.1 else { continue }
                    found.append(AccessoryBattery(name: name, symbol: symbol(for: name, kind: d["device_minorType"] as? String ?? ""),
                                                  percent: lowest,
                                                  parts: parts.isEmpty ? nil : parts.map { "\($0.0) \($0.1)%" }.joined(separator: " · ")))
                }
            }
        }
        return found
    }

    nonisolated static func symbol(for name: String, kind: String) -> String {
        let n = name.lowercased(), k = kind.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("mouse") || k.contains("mouse") { return "magicmouse.fill" }
        if n.contains("trackpad") || k.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if n.contains("keyboard") || k.contains("keyboard") { return "keyboard.fill" }
        if k.contains("head") || n.contains("beats") || n.contains("buds") { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}

/// Battery and accessories, shared by every view that shows them. Power-source changes (plug,
/// unplug, each percent) arrive as notifications; a slow timer covers the rest.
@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()
    private static let refreshInterval: TimeInterval = 60
    private static let bluetoothInterval: TimeInterval = 900

    @Published private(set) var state = BatteryReader.read()
    @Published private(set) var accessories: [AccessoryBattery] = []

    /// Called after every refresh (the alert rules listen here).
    var onChange: [() -> Void] = []
    private var bluetooth: [AccessoryBattery] = []
    private var timer: Timer?
    private var lastBluetooth = Date.distantPast
    private var bluetoothRunning = false

    private init() {
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { BatteryMonitor.shared.refresh() } }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BatteryMonitor.shared.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { BatteryMonitor.shared.refresh() }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { BatteryMonitor.shared.refresh(accessories: true) } }
    }

    /// Re-reads the battery; `accessories` forces the slow Bluetooth read too.
    func refresh(accessories force: Bool = false) {
        let fresh = BatteryReader.read()
        if fresh != state { state = fresh }
        publishAccessories(hid: AccessoryReader.readHID())
        // system_profiler is the slow part: only for accessory alerts, or when a view asks (force).
        let prefs = BatteryPreferences.shared
        let wanted = prefs.alertsEnabled && prefs.accessoryAlert && !SystemActivity.userAway
        if force || (wanted && Date().timeIntervalSince(lastBluetooth) > Self.bluetoothInterval) { refreshBluetooth() }
        onChange.forEach { $0() }
    }

    private func publishAccessories(hid: [AccessoryBattery]) {
        let merged = (hid + bluetooth.filter { b in !hid.contains { $0.name == b.name } }).sorted { $0.percent < $1.percent }
        if merged != accessories { accessories = merged }
    }

    private func refreshBluetooth() {
        guard !bluetoothRunning else { return }
        bluetoothRunning = true
        lastBluetooth = Date()
        DispatchQueue.global(qos: .utility).async {
            let found = AccessoryReader.readBluetooth()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let monitor = BatteryMonitor.shared
                    monitor.bluetoothRunning = false
                    monitor.bluetooth = found
                    monitor.publishAccessories(hid: AccessoryReader.readHID())
                    monitor.onChange.forEach { $0() }
                }
            }
        }
    }
}

extension BatteryMonitor {
    /// Low Power Mode needs root to change: macOS asks for an administrator password.
    func setLowPowerMode(_ on: Bool) {
        let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 { NSLog("win-tab: low power mode failed: \(error)") }
        refresh()
    }
}

/// Whether anyone is at the Mac, so background sampling can pause while they're away.
enum SystemActivity {
    /// No keyboard, mouse or trackpad input for this long counts as away.
    static let awayAfter: TimeInterval = 300

    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static var userAway: Bool { idleSeconds > awayAfter || screenLocked }
}
