import AppKit
import Darwin
import IOKit
import SwiftUI

/// One reading of the Mac: CPU, memory, GPU, disk, network and the busiest apps.
struct SystemSnapshot {
    struct App: Identifiable, Equatable {
        let pid: pid_t
        let name: String
        let bundleID: String?
        /// Percent of one core, like Activity Monitor (can pass 100).
        let cpu: Double
        /// Physical footprint of the app and its helper processes.
        let memory: UInt64
        var id: pid_t { pid }
    }

    var cpu: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    var pressure = 1
    var gpu: Double?
    /// System memory the GPU has in use.
    var gpuMemory: UInt64?
    var diskFree: Int64?
    var diskTotal: Int64?
    var netIn: Double = 0
    var netOut: Double = 0
    var apps: [App] = []
}

/// Samples the system only while the notch's System tab is on screen.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    static let intervalKey = "switch.notch.system.interval"
    static let sortKey = "switch.notch.system.sort"

    @Published private(set) var snapshot = SystemSnapshot()
    private var timer: Timer?
    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "win-tab.system", qos: .utility)

    private var interval: TimeInterval {
        let base = UserDefaults.standard.object(forKey: Self.intervalKey) as? Double ?? 2
        return EnergySaver.isOn ? base * 2 : base
    }

    func setActive(_ active: Bool) {
        guard active != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard active else { return }
        warmUp()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = interval * 0.1
        timer = t
    }

    /// CPU readings are differences between two reads; the counters kept from the last time the
    /// tab was open would give that whole stretch's average (or 0 the first time). Read once to
    /// reset them, then show a reading taken half a second later.
    private static let warmUpDelay: TimeInterval = 0.5

    private func warmUp() {
        let own = ProcessInfo.processInfo.processIdentifier
        queue.async { [sampler] in _ = sampler.read(excluding: own) }
        queue.asyncAfter(deadline: .now() + Self.warmUpDelay) { [weak self] in
            DispatchQueue.main.async { self?.sample() }
        }
    }

    /// Called after a quit so the row goes away without waiting for the next tick.
    func refreshSoon() {
        queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            DispatchQueue.main.async { self?.sample() }
        }
    }

    private func sample() {
        let own = ProcessInfo.processInfo.processIdentifier
        queue.async { [sampler] in
            let next = sampler.read(excluding: own)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.35)) { self.snapshot = next }
            }
        }
    }
}

/// The readings themselves, on a background queue. Keeps the previous counters to turn them
/// into rates.
private final class SystemSampler: @unchecked Sendable {
    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var lastNet: (inBytes: UInt64, outBytes: UInt64, at: TimeInterval)?
    private var lastProc: [pid_t: UInt64] = [:]
    private var lastProcAt: TimeInterval = 0
    private var apps: [(pid: pid_t, name: String, bundleID: String?)] = []
    private var appsAt: TimeInterval = 0
    private let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private static let hidden: Set<String> = ["com.apple.finder"]

    func read(excluding own: pid_t) -> SystemSnapshot {
        var s = SystemSnapshot()
        s.cpu = cpu()
        (s.memoryUsed, s.pressure) = memory()
        (s.gpu, s.gpuMemory) = gpu()
        (s.diskFree, s.diskTotal) = disk()
        (s.netIn, s.netOut) = network()
        s.apps = topApps(excluding: own)
        return s
    }

    /// Whole machine, busy share of all cores, from tick counters.
    private func cpu() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return 0 }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1), idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        let busy = user + system + nice, total = busy + idle
        defer { lastCPU = (busy, total) }
        guard let last = lastCPU, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    /// Activity Monitor's "Memory Used": app memory (internal − purgeable) + wired + compressed.
    private func memory() -> (UInt64, Int) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        var pressure: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        guard ok == KERN_SUCCESS else { return (0, Int(pressure)) }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(vm.internal_page_count) - min(UInt64(vm.purgeable_count), UInt64(vm.internal_page_count))
        let used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        return (used, Int(pressure))
    }

    /// "Device Utilization %" from the GPU driver's performance statistics.
    private func gpu() -> (Double?, UInt64?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOObjectRelease(iterator) }
        var best: Double?, memory: UInt64?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            if let u = stats?["Device Utilization %"] as? NSNumber { best = max(best ?? 0, u.doubleValue / 100) }
            if let m = stats?["In use system memory"] as? NSNumber { memory = (memory ?? 0) + m.uint64Value }
        }
        return (best, memory)
    }

    private func disk() -> (Int64?, Int64?) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacityForImportantUsage, v?.volumeTotalCapacity.map(Int64.init))
    }

    /// Bytes per second in and out over every interface but loopback.
    private func network() -> (Double, Double) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = p.pointee.ifa_data?.assumingMemoryBound(to: if_data.self),
                  String(cString: p.pointee.ifa_name) != "lo0" else { continue }
            inBytes += UInt64(data.pointee.ifi_ibytes)
            outBytes += UInt64(data.pointee.ifi_obytes)
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastNet = (inBytes, outBytes, now) }
        // Counters are 32-bit per interface and wrap; a negative step is skipped.
        guard let last = lastNet, now > last.at, inBytes >= last.inBytes, outBytes >= last.outBytes else { return (0, 0) }
        let dt = now - last.at
        return (Double(inBytes - last.inBytes) / dt, Double(outBytes - last.outBytes) / dt)
    }

    /// Regular apps with their helper processes folded in (a helper counts for the first regular
    /// app up its parent chain).
    // ponytail: parent chain only; XPC helpers launchd starts (Safari's WebContent) count for no app.
    private func topApps(excluding own: pid_t) -> [SystemSnapshot.App] {
        let now = ProcessInfo.processInfo.systemUptime
        if now - appsAt > 5 || apps.isEmpty {
            // NSRunningApplication properties ask LaunchServices; every few seconds is plenty.
            apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != own && !Self.hidden.contains($0.bundleIdentifier ?? "") }
                .map { ($0.processIdentifier, $0.localizedName ?? "", $0.bundleIdentifier) }
            appsAt = now
        }
        let appPIDs = Set(apps.map(\.pid))
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var parent: [pid_t: pid_t] = [:]
        var cpuTime: [pid_t: UInt64] = [:]
        var footprint: [pid_t: UInt64] = [:]
        for pid in pids.prefix(max(n, 0)) where pid > 0 {
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { continue }  // other users': EPERM
            cpuTime[pid] = task.pti_total_user + task.pti_total_system
            var bsd = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 { parent[pid] = pid_t(bsd.pbi_ppid) }
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if ok == 0 { footprint[pid] = usage.ri_phys_footprint }
        }
        let dt = now - lastProcAt
        var cpuByApp: [pid_t: Double] = [:], memByApp: [pid_t: UInt64] = [:]
        for (pid, time) in cpuTime {
            var owner = pid, hops = 0
            while !appPIDs.contains(owner), let up = parent[owner], up > 1, hops < 8 { owner = up; hops += 1 }
            guard appPIDs.contains(owner) else { continue }
            memByApp[owner, default: 0] += footprint[pid] ?? 0
            if let before = lastProc[pid], time >= before, dt > 0 {
                cpuByApp[owner, default: 0] += Double(time - before) * timebase / 1e9 / dt * 100
            }
        }
        lastProc = cpuTime
        lastProcAt = now
        return apps.map { SystemSnapshot.App(pid: $0.pid, name: $0.name, bundleID: $0.bundleID, cpu: cpuByApp[$0.pid] ?? 0, memory: memByApp[$0.pid] ?? 0) }
    }
}

// MARK: - View

/// The notch's System tab: four gauges on the left; on the right the busiest apps (with Quit),
/// Optimize actions, or the network (public IP, flag, VPN).
struct NotchSystemView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case cpu, memory
        var id: String { rawValue }
        var label: String { self == .cpu ? "CPU" : "Memory" }
        /// Header over the app list.
        var heading: String { self == .cpu ? "Using the most CPU" : "Using the most memory" }
    }

    enum Page: String, CaseIterable, Identifiable {
        case apps, optimize, network
        var id: String { rawValue }
        var label: String {
            switch self {
            case .apps: return "Top apps"
            case .optimize: return "Free up"
            case .network: return "Network"
            }
        }
    }

    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var net = NetworkInfo.shared
    @AppStorage(SystemMonitor.sortKey) private var sort: Sort = .cpu
    @AppStorage("switch.notch.system.page") private var page: Page = .apps
    @Environment(\.notchOpen) private var notchOpen
    @State private var shown = false
    /// Rows that fit under the page bar without scrolling.
    private static let rows = 4

    var body: some View {
        let s = monitor.snapshot
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                SystemStatusLine(status: status(s))
                SystemMeter(title: "CPU", value: s.cpu, color: load(s.cpu),
                            reading: "\(percent(s.cpu)) busy", help: "All \(Self.cores) cores together")
                SystemMeter(title: "Memory", value: Double(s.memoryUsed) / Double(max(s.memoryTotal, 1)), color: pressureColor(s.pressure),
                            reading: "\(number(s.memoryUsed)) of \(gb(s.memoryTotal))", help: "Memory in use · \(pressureWord(s.pressure)) pressure")
                SystemMeter(title: "GPU", value: s.gpu ?? 0, color: load(s.gpu ?? 0),
                            reading: s.gpu.map { "\(percent($0)) busy" } ?? "–", help: s.gpuMemory.map { "Graphics using \(gb($0)) of memory" } ?? "Graphics")
                SystemMeter(title: "Disk", value: diskUsed(s), color: diskUsed(s) > 0.9 ? .orange : .teal,
                            reading: s.diskFree.map { "\(gb(UInt64(max($0, 0)))) free" } ?? "–", help: "\(percent(diskUsed(s))) of the startup disk used")
                HStack(spacing: 10) {
                    Label(SystemFormat.rate(s.netIn), systemImage: "arrow.down").foregroundStyle(.cyan).help("Download")
                    Label(SystemFormat.rate(s.netOut), systemImage: "arrow.up").foregroundStyle(.pink).help("Upload")
                    Spacer(minLength: 0)
                    if net.vpn != nil {
                        Label("VPN", systemImage: "lock.shield.fill").foregroundStyle(.green).help("A VPN is connected")
                    }
                    if let country = net.publicInfo?.country {
                        Text(SystemFormat.flag(country)).help("You appear online from \(Locale.current.localizedString(forRegionCode: country) ?? country)")
                    }
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            }
            .frame(width: 236)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(Page.allCases) { p in
                        SystemPill(title: p.label, on: page == p) { withAnimation(.easeOut(duration: 0.2)) { page = p } }
                    }
                    Spacer(minLength: 0)
                    if page == .apps {
                        ForEach(Sort.allCases) { option in
                            SystemPill(title: option.label, on: sort == option) {
                                withAnimation(.easeOut(duration: 0.2)) { sort = option }
                            }
                        }
                    }
                }
                Group {
                    switch page {
                    case .apps: appsList(s)
                    case .optimize: NotchSystemOptimizePage(snapshot: s)
                    case .network: NotchSystemNetworkPage(snapshot: s)
                    }
                }
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { shown = true; monitor.setActive(notchOpen); net.refresh() }
        .onDisappear { shown = false; monitor.setActive(false) }
        .onChange(of: notchOpen) { _, open in monitor.setActive(open && shown) }
    }

    private func appsList(_ s: SystemSnapshot) -> some View {
        let apps = s.apps.sorted { sort == .cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }.prefix(Self.rows)
        let top = max(apps.first.map { sort == .cpu ? $0.cpu : Double($0.memory) } ?? 1, 1)
        return VStack(alignment: .leading, spacing: 3) {
            Text(sort.heading).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            ForEach(Array(apps)) { app in
                SystemAppRow(app: app, value: sort == .cpu ? String(format: "%.0f%% CPU", app.cpu) : gb(app.memory),
                             share: (sort == .cpu ? app.cpu : Double(app.memory)) / top)
            }
            if apps.isEmpty {
                Text("Reading…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private static let cores = ProcessInfo.processInfo.activeProcessorCount
    /// GB without the unit, for "40/48 GB".
    private func number(_ bytes: UInt64) -> String { String(format: "%.0f", Double(bytes) / 1_073_741_824) }
    private func gb(_ bytes: UInt64) -> String { SystemFormat.gb(bytes) }
    private func diskUsed(_ s: SystemSnapshot) -> Double {
        guard let free = s.diskFree, let total = s.diskTotal, total > 0 else { return 0 }
        return 1 - Double(free) / Double(total)
    }
    private func load(_ v: Double) -> Color { v > 0.85 ? .red : v > 0.6 ? .orange : .green }
    private func percent(_ v: Double) -> String { "\(Int((min(max(v, 0), 1) * 100).rounded()))%" }
    private func pressureWord(_ level: Int) -> String { level >= 4 ? "critical" : level >= 2 ? "high" : "normal" }

    /// One plain sentence on the whole Mac, worst first.
    private func status(_ s: SystemSnapshot) -> SystemStatusLine.Status {
        if s.pressure >= 4 { return .init(text: "Memory is full: quit an app you don't need", color: .red) }
        if s.pressure >= 2 { return .init(text: "Memory is getting tight", color: .orange) }
        if s.cpu > 0.85 { return .init(text: "CPU is very busy", color: .orange) }
        if diskUsed(s) > 0.9 { return .init(text: "Disk is almost full", color: .orange) }
        return .init(text: "Your Mac is running normally", color: .green)
    }
    private func pressureColor(_ level: Int) -> Color { level >= 4 ? .red : level >= 2 ? .orange : .blue }
}

/// A dot and one sentence: how the Mac is doing overall.
struct SystemStatusLine: View {
    struct Status: Equatable {
        let text: String
        let color: Color
    }

    let status: Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 7, height: 7).shadow(color: status.color.opacity(0.7), radius: 3)
            Text(status.text).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(height: 16)
    }
}

/// Name, a bar for how full it is, and the reading in words ("27% busy", "54 GB free").
private struct SystemMeter: View {
    let title: String
    let value: Double
    let color: Color
    let reading: String
    let help: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.6)).frame(width: 46, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: max(4, g.size.width * CGFloat(min(max(value, 0), 1))))
                    }
            }
            .frame(height: 6)
            Text(reading)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
                .frame(width: 76, alignment: .trailing)
        }
        .frame(height: 19)
        .contentShape(Rectangle())
        .help(help)
    }
}

/// Icon, name, a bar for its share, the value, and Quit (⌥ force quits).
private struct SystemAppRow: View {
    let app: SystemSnapshot.App
    let value: String
    let share: Double
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let bid = app.bundleID, let icon = AppIcons.icon(bundleID: bid) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                GeometryReader { g in
                    Capsule().fill(.white.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.55)).frame(width: max(3, g.size.width * CGFloat(min(max(share, 0), 1))))
                        }
                }
                .frame(height: 3)
            }
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
                .contentTransition(.numericText())
                .frame(width: 58, alignment: .trailing)
            Button(action: quit) {
                Text("Quit")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.75)))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Quit \(app.name) (⌥-click to force quit)")
        }
        .frame(height: 22)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func quit() {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        if NSEvent.modifierFlags.contains(.option) { running.forceTerminate() } else { running.terminate() }
        SystemMonitor.shared.refreshSoon()
    }
}
