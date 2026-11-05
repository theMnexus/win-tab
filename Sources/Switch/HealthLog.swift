import Darwin
import Foundation
import os

/// One line an hour in the unified log: the app's own CPU and memory, so a slow climb shows up
/// without attaching a profiler. A 47-hour-old process once idled at 9-19 % CPU and 198 MB while
/// a fresh one idles under 1 % and 115 MB; nothing recorded when that started. Read with:
///
///     /usr/bin/log show --predicate 'subsystem == "com.mn.wintab" AND category == "health"' --last 7d
@MainActor
enum HealthLog {
    private static let log = Logger(subsystem: "com.mn.wintab", category: "health")
    private static let every: TimeInterval = 3600
    /// An hour averaging more CPU than this is logged as an error, so it stands out.
    private static let busyPercent = 3.0

    private static var timer: Timer?
    private static var launched = Date()
    private static var last = (cpu: 0.0, at: Date())

    static func start() {
        guard timer == nil else { return }
        launched = Date()
        last = (cpuSeconds(), Date())
        let t = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
            MainActor.assumeIsolated { report() }
        }
        t.tolerance = 60
        timer = t
    }

    private static func report() {
        let now = (cpu: cpuSeconds(), at: Date())
        let wall = now.at.timeIntervalSince(last.at)
        guard wall > 0 else { return }
        let percent = (now.cpu - last.cpu) / wall * 100
        last = now
        let hours = Int(now.at.timeIntervalSince(launched) / 3600)
        let line = String(format: "up %ld h · CPU %.1f %% over the last hour · memory %ld MB", hours, percent, footprintMB())
        if percent >= busyPercent {
            log.error("\(line, privacy: .public) · busy while idle?")
        } else {
            log.notice("\(line, privacy: .public)")
        }
    }

    /// User + system CPU time of this process, in seconds.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// The figure Activity Monitor shows as Memory.
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }
}
