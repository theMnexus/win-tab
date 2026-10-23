// Regression check for window focus. Needs the Debug build running with Accessibility + Screen Recording:
//   swift tools/focus-test.swift          current-Space windows, two rounds in opposite orders
//   swift tools/focus-test.swift --cross  also pull in windows from other desktop Spaces (moves them here)
// Exits non-zero if any focus lands on the wrong app or window.
import AppKit
func post(_ name: String, _ info: [String: String]? = nil) {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: nil, userInfo: info, deliverImmediately: true)
}
func dump() -> [String: Any] {
    try? FileManager.default.removeItem(atPath: "/tmp/switch_debug.json")
    post("switch.debug.dump")
    for _ in 0..<40 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if let d = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/switch_debug.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
    }
    fatalError("harness did not answer; is the Debug win-tab running?")
}
func topWindow() -> (wid: Int, pid: Int)? {
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for d in raw where (d[kCGWindowLayer as String] as? Int) == 0 {
        let owner = d[kCGWindowOwnerName as String] as? String ?? ""
        if owner == "win-tab" { continue }
        // Same size floor as win-tab's enumerator: skip strips and shells (e.g. a 2560x38 title bar).
        let b = d[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        if (b["Width"] ?? 0) < 100 || (b["Height"] ?? 0) < 80 { continue }
        return (d[kCGWindowNumber as String] as? Int ?? 0, d[kCGWindowOwnerPID as String] as? Int ?? 0)
    }
    return nil
}
let includeCross = CommandLine.arguments.contains("--cross")
let d = dump()
var targets = (d["activeSpaceWindows"] as? [[String: Any]] ?? [])
if includeCross { targets += (d["crossSpaceWindows"] as? [[String: Any]] ?? []).filter { ($0["fullscreenSpace"] as? Bool) != true } }
var pass = 0, fail = 0
// Two rounds in reverse orders so each window is switched to from a different predecessor.
for round in [targets, targets.reversed()] {
    for w in round {
        let wid = w["wid"] as! Int, pid = w["pid"] as! Int
        post("switch.debug.focus", ["wid": String(wid), "strategy": "current"])
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let top = topWindow()
        let ok = Int(front) == pid && top?.wid == wid
        ok ? (pass += 1) : (fail += 1)
        print(ok ? "PASS" : "FAIL", wid, w["app"] ?? "", "| front pid \(front) want \(pid) | top wid \(top?.wid ?? -1)")
    }
}
print("RESULT pass=\(pass) fail=\(fail)")
exit(fail == 0 ? 0 : 1)
