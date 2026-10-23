#if DEBUG
import AppKit
import SwiftUI

/// Debug-build-only test rig: drive focus strategies from the command line and
/// read back what actually happened, since external processes lack AX trust.
///
///   post "switch.debug.dump"                       → /tmp/switch_debug.json
///   post "switch.debug.shot" {"wid": "x,y,w,h"}  → /tmp/switch_shot.png (screen region)
///   post "switch.debug.dockdump"                   → /tmp/switch_debug_dock.json (Dock items, badges, hover)
///   post "switch.debug.layoutcheck"                → /tmp/switch_debug_layout.txt (PASS or failures)
///   post "switch.debug.slsdump"                    → /tmp/switch_debug_sls.json (raw CG + WindowServer tags)
///   post "switch.debug.focus" {"wid": N, "strategy": S} → focuses, then dumps
///     strategies: current | slps | slps-noax | slps-activate
final class DebugFocusHarness {
    private var tokens: [NSObjectProtocol] = []

    func start() {
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.dump"), object: nil, queue: .main
        ) { _ in
            Self.dump(to: "/tmp/switch_debug.json")
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.focus"), object: nil, queue: .main
        ) { note in
            guard let widStr = note.userInfo?["wid"] as? String,
                  let wid = UInt32(widStr),
                  let strategy = note.userInfo?["strategy"] as? String else { return }
            Self.runFocus(wid: CGWindowID(wid), strategy: strategy)
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.thumb"), object: nil, queue: .main
        ) { note in
            // wid = window id; writes what the thumbnail cache would hold.
            guard let wid = (note.userInfo?["wid"] as? String).flatMap(UInt32.init) else { return }
            Task {
                let img = await WindowSnapshotter.shared.snapshot(for: CGWindowID(wid), force: true)
                guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: "/tmp/switch_thumb_\(wid).png"))
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.settings"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SettingsWindow.shared.show() }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.shot"), object: nil, queue: .main
        ) { note in
            // wid = "x,y,w,h" in global top-left coordinates.
            let parts = (note.userInfo?["wid"] as? String ?? "").split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else { return }
            Self.shot(CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]))
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.dockdump"), object: nil, queue: .main
        ) { _ in
            Self.dockDump()
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.ocrfile"), object: nil, queue: .main
        ) { note in
            // wid = image path: runs the OCR recognizer on it and writes the text and timing.
            guard let path = note.userInfo?["wid"] as? String,
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            Task.detached {
                let start = Date()
                let text = await OCRCapture.recognize(image)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                try? "\(ms) ms\n\(text)".write(toFile: "/tmp/switch_debug_ocr.txt", atomically: true, encoding: .utf8)
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.chromejs"), object: nil, queue: .main
        ) { _ in
            // Whether Chrome runs JavaScript sent over Apple Events (View › Developer setting).
            var error: NSDictionary?
            let out = NSAppleScript(source: "tell application \"Google Chrome\" to execute active tab of front window javascript \"1+1\"")?
                .executeAndReturnError(&error)
            let text = error.map { "ERROR \($0)" } ?? "OK \(out?.stringValue ?? "")"
            try? text.write(toFile: "/tmp/switch_debug_chromejs.txt", atomically: true, encoding: .utf8)
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.notchanim"), object: nil, queue: .main
        ) { _ in
            // Toggles the island and measures frame delivery on the main thread while it animates.
            MainActor.assumeIsolated {
                FrameMeter.shared.measure(seconds: 0.8, label: "toggle") { NotchController.debugShared?.debugToggle() }
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.frames"), object: nil, queue: .main
        ) { note in
            // Measures frame delivery for N seconds while something else (a pointer sweep) runs.
            let seconds = (note.userInfo?["wid"] as? String).flatMap(Double.init) ?? 3
            MainActor.assumeIsolated { FrameMeter.shared.measure(seconds: seconds, label: "window") {} }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.illustrations"), object: nil, queue: .main
        ) { _ in
            // Renders the Settings illustrations off screen, for checking without opening Settings.
            MainActor.assumeIsolated {
                let views: [(String, AnyView)] = [
                    ("dockpreview", AnyView(DockLivePreview().frame(width: 720).padding(10).background(Color(white: 0.12)))),
                    ("notchpreview", AnyView(NotchIllustration().frame(width: 720).padding(10).background(Color(white: 0.12)))),
                    ("notchlayout", AnyView(NotchLayoutEditor().frame(width: 720).background(Color(white: 0.12)))),
                    ("reveal", AnyView(VStack { DockRevealBarStyleRows() }.frame(width: 560).padding(16).background(Color(white: 0.12)))),
                    ("stack", AnyView(DockStackPanel.debugPreview().padding(30).background(Color(white: 0.08)))),
                    ("styles", AnyView(VStack(spacing: 20) { DockStyleSection(); NotchStyleSection(); WindowStyleSection() }
                        .frame(width: 720).padding(16).background(Color(white: 0.12)))),
                ]
                for (name, view) in views {
                    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
                    renderer.scale = 2
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "/tmp/switch_\(name).png"))
                    }
                }
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.notchtrace"), object: nil, queue: .main
        ) { _ in
            // Toggles the island and logs its on-screen size and content opacity every ~16 ms.
            MainActor.assumeIsolated {
                let marker = "controller=\(NotchController.debugShared != nil) island=\(NotchController.debugShared?.debugIsland != nil)"
                try? marker.write(toFile: "/tmp/switch_debug_notchtrace_marker.txt", atomically: true, encoding: .utf8)
                guard let controller = NotchController.debugShared, let island = controller.debugIsland else { return }
                var rows: [String] = []
                let start = CACurrentMediaTime()
                controller.debugToggle()
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
                    MainActor.assumeIsolated {
                        let s = island.presentedSize
                        rows.append(String(format: "%4.0fms w=%6.1f h=%6.1f content=%.2f ", (CACurrentMediaTime() - start) * 1000, s.width, s.height, island.presentedContentOpacity) + island.debugState)
                        if CACurrentMediaTime() - start > 0.75 {
                            t.invalidate()
                            try? rows.joined(separator: "\n").write(toFile: "/tmp/switch_debug_notchtrace.txt", atomically: true, encoding: .utf8)
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.notchstate"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let island = NotchController.debugShared?.debugIsland else { return }
                let text = "\(island.debugState) mode=\(NotchActivity.mode) presented=\(island.presentedSize)"
                try? text.write(toFile: "/tmp/switch_debug_notchstate.txt", atomically: true, encoding: .utf8)
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.dockconceal"), object: nil, queue: .main
        ) { note in
            // arg "hide" / "show" animates the Dock's hide; "hold" parks it part way (for a still
            // shot of the direction). Traces the layer to /tmp/switch_debug_conceal.txt.
            MainActor.assumeIsolated {
                let arg = note.userInfo?["wid"] as? String ?? "hide"
                guard let canvas = NSApp.windows.compactMap({ $0.contentView as? CustomDockCanvas }).first, let layer = canvas.layer else { return }
                if arg == "hold" {
                    canvas.conceal(true, slide: true, fade: false, duration: nil)
                    let t = layer.sublayerTransform
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.sublayerTransform = CATransform3DMakeTranslation(t.m41 * 0.4, t.m42 * 0.4, 0)
                    CATransaction.commit()
                    return
                }
                canvas.conceal(arg == "hide", slide: true, fade: arg == "hide", duration: 0.35)
                var lines = ["flipped=\(layer.isGeometryFlipped) bounds=\(canvas.bounds)"]
                let start = CACurrentMediaTime()
                Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        let p = layer.presentation() ?? layer
                        lines.append(String(format: "%.3f ty=%.1f tx=%.1f op=%.2f", CACurrentMediaTime() - start,
                                            p.sublayerTransform.m42, p.sublayerTransform.m41, p.opacity))
                        if CACurrentMediaTime() - start > 0.7 {
                            timer.invalidate()
                            try? lines.joined(separator: "\n").write(toFile: "/tmp/switch_debug_conceal.txt", atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.battery"), object: nil, queue: .main
        ) { note in
            // arg low | high | full | plug | unplug | glow | tab: shows that alert (or opens Settings → Battery).
            MainActor.assumeIsolated {
                let arg = note.userInfo?["wid"] as? String ?? "low"
                // page:<name> / notch:<name> pick a Settings → Battery page or the notch's battery page.
                if arg.hasPrefix("page:") { UserDefaults.standard.set(String(arg.dropFirst(5)), forKey: "switch.battery.settingsPage"); return }
                if arg.hasPrefix("alertdisplay:") { SwitchPreferences.shared.alertDisplay = .init(rawValue: String(arg.dropFirst(13))) ?? .main; return }
                if arg.hasPrefix("popup:") { NotificationFeed.shared.popup = .init(rawValue: String(arg.dropFirst(6))) ?? .banner; return }
                if arg.hasPrefix("density:") { NotificationFeed.shared.density = .init(rawValue: String(arg.dropFirst(8))) ?? .comfortable; return }
                if arg.hasPrefix("tabextra:") { NotificationFeed.shared.tabExtra = Double(arg.dropFirst(9)) ?? 110; return }
                if arg.hasPrefix("theme:") { BatteryPreferences.shared.bubbleTheme = .init(rawValue: String(arg.dropFirst(6))) ?? .glass; return }
                if arg.hasPrefix("notchstyle:") { BatteryPreferences.shared.notchAlertStyle = .init(rawValue: String(arg.dropFirst(11))) ?? .expanded; return }
                if arg.hasPrefix("notch:") { UserDefaults.standard.set(String(arg.dropFirst(6)), forKey: "switch.notch.batteryPage"); return }
                switch arg {
                case "high": BatteryAlertCenter.shared.present(.charged(level: 80))
                case "full": BatteryAlertCenter.shared.present(.charged(level: 100))
                case "plug": BatteryAlertCenter.shared.present(.pluggedIn)
                case "unplug": BatteryAlertCenter.shared.present(.unplugged)
                case "tab": SettingsWindow.shared.show(tab: "battery")
                case "tabhit":
                    let text = NotchController.debugShared?.debugIsland?.debugTabBarHit() ?? "no island"
                    try? text.write(toFile: "/tmp/switch_debug_hit.txt", atomically: true, encoding: .utf8)
                case "hit":
                    let text = NotchController.debugShared?.debugIsland?.debugHit(below: [50, 60, 100, 140], x: 80) ?? "no island"
                    try? text.write(toFile: "/tmp/switch_debug_hit.txt", atomically: true, encoding: .utf8)
                case "render":
                    // The overview, hero and grid, drawn off screen to /tmp/switch_battery.png.
                    guard let b = BatteryMonitor.shared.state else { return }
                    let view = VStack(spacing: 14) {
                        BatteryHero(battery: b).padding(18).background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
                        BatteryStatsGrid(battery: b)
                        HStack(spacing: 20) {
                            ForEach([100, 64, 35, 12], id: \.self) { p in
                                BatteryGlyph(percent: p, charging: p == 64, color: BatteryPalette.color(percent: p, charging: p == 64), height: 12)
                            }
                            BatteryGlyph(percent: 64, color: .white, height: 12)
                        }
                    }
                    .padding(20).frame(width: 720).background(Color(white: 0.12)).environment(\.colorScheme, .dark)
                    let r = ImageRenderer(content: view)
                    r.scale = 2
                    if let tiff = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "/tmp/switch_battery.png"))
                    }
                case "center": BatteryAlertCenter.shared.present(.low(level: 10), style: AlertStyle(position: .center, glow: false, persistent: false, sound: "None"))
                case "fakenotif": NotificationFeed.shared.debugInject()
                case "rendersetup":
                    let r = ImageRenderer(content: NotificationSetupList().frame(width: 620).padding(.vertical, 10)
                        .background(Color(white: 0.14)).environment(\.colorScheme, .dark))
                    r.scale = 2
                    if let tiff = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "/tmp/switch_setup.png"))
                    }
                case "replyrow":
                    NotificationFeed.shared.debugOpenRow = 9_000_003
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let key = NSApp.windows.first { $0 is NotchPanel }.map { "notch key=\($0.isKeyWindow) canBecomeKey=\($0.canBecomeKey)" } ?? "no panel"
                        try? key.write(toFile: "/tmp/switch_debug_key.txt", atomically: true, encoding: .utf8)
                    }
                case "ncdump":
                    // Notification Center's accessibility tree (roles, subroles, actions) → /tmp/switch_debug_nc.txt
                    var lines: [String] = []
                    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui") {
                        let root = AXUIElementCreateApplication(app.processIdentifier)
                        func walk(_ el: AXUIElement, _ depth: Int) {
                            guard depth < 12, lines.count < 400 else { return }
                            func attr(_ name: String) -> String {
                                var v: CFTypeRef?
                                AXUIElementCopyAttributeValue(el, name as CFString, &v)
                                return v.map { "\($0)" }.map { $0.count > 60 ? String($0.prefix(60)) : $0 } ?? "-"
                            }
                            var actions: CFArray?
                            AXUIElementCopyActionNames(el, &actions)
                            let names = (actions as? [String] ?? []).map { $0.components(separatedBy: "\n").first ?? $0 }
                            lines.append(String(repeating: "  ", count: depth) + "\(attr("AXRole")) \(attr("AXSubrole")) id=\(attr("AXIdentifier")) actions=\(names)")
                            var kids: CFTypeRef?
                            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
                            for k in kids as? [AXUIElement] ?? [] { walk(k, depth + 1) }
                        }
                        walk(root, 0)
                    }
                    try? lines.joined(separator: "\n").write(toFile: "/tmp/switch_debug_nc.txt", atomically: true, encoding: .utf8)
                case "openhome": NotchController.debugShared?.debugOpen(tab: .home)
                case "openclip": NotchController.debugShared?.debugOpen(tab: .clipboard)
                case "opensystem": NotchController.debugShared?.debugOpen(tab: .system)
                case "openports": NotchController.debugShared?.debugOpen(tab: .ports)
                case "opennotif":
                    NotchController.debugShared?.debugOpen(tab: .notifications)
                case "open":
                    // Opens the notch on the Battery tab and holds it for a screenshot.
                    SwitchPreferences.shared.notchTabs.insert("battery")
                    NotchController.debugShared?.debugOpen(tab: .battery)
                default: BatteryAlertCenter.shared.present(.low(level: 20))
                }
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.group"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CustomDockController.debugShared?.debugToggleGroup() }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.stalls"), object: nil, queue: .main
        ) { _ in
            // Main-thread stalls over 20 s (gaps > 25 ms between 60 Hz ticks), and a hover sweep.
            MainActor.assumeIsolated {
                var lines: [String] = []
                if let canvas = NSApp.windows.compactMap({ $0.contentView as? CustomDockCanvas }).first {
                    let r = canvas.debugHoverSweep()
                    lines.append(String(format: "hover sweep: avg %.2f ms, max %.2f ms per step", r.avg, r.max))
                }
                var last = CACurrentMediaTime()
                let start = last
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
                    MainActor.assumeIsolated {
                        let now = CACurrentMediaTime()
                        let gap = (now - last) * 1000
                        if gap > 25 { lines.append(String(format: "stall %.0f ms at +%.1f s", gap, now - start)) }
                        last = now
                        if now - start > 20 {
                            t.invalidate()
                            try? lines.joined(separator: "\n").write(toFile: "/tmp/switch_debug_stalls.txt", atomically: true, encoding: .utf8)
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.dockitems"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let text = CustomDockController.debugShared?.debugItems() ?? "no dock"
                try? text.write(toFile: "/tmp/switch_debug_dockitems.txt", atomically: true, encoding: .utf8)
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.dockmove"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let text = CustomDockController.debugShared?.debugDropMiddle() {
                    try? text.write(toFile: "/tmp/switch_debug_dropmid.txt", atomically: true, encoding: .utf8)
                }
                CustomDockController.debugShared?.debugDragAll { text in
                    try? text.write(toFile: "/tmp/switch_debug_dockmove.txt", atomically: true, encoding: .utf8)
                }
            }
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.layoutcheck"), object: nil, queue: .main
        ) { _ in
            let failures = CustomDockLayout.selfCheck() + StylePreferences.selfCheck() + DockStackPanel.Metrics.selfCheck() + BatteryAlertRules.selfCheck() + SMC.selfCheck() + BatteryHistory.selfCheck() + NotificationFeed.selfCheck() + NotificationStyles.selfCheck() + NowPlayingMonitor.selfCheck()
            let text = failures.isEmpty ? "PASS" : "FAIL\n" + failures.prefix(40).joined(separator: "\n")
            try? text.write(toFile: "/tmp/switch_debug_layout.txt", atomically: true, encoding: .utf8)
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.slsdump"), object: nil, queue: .main
        ) { _ in
            Self.slsDump()
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.axdump"), object: nil, queue: .main
        ) { note in
            guard let pidStr = note.userInfo?["wid"] as? String, let pid = Int32(pidStr) else { return }
            Self.axDump(pid: pid)
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.axcapture"), object: nil, queue: .main
        ) { note in
            guard let pidStr = note.userInfo?["wid"] as? String, let pid = Int32(pidStr) else { return }
            Self.capture(pid: pid)
        })
        tokens.append(dnc.addObserver(
            forName: Notification.Name("switch.debug.axenable"), object: nil, queue: .main
        ) { note in
            guard let pidStr = note.userInfo?["wid"] as? String, let pid = Int32(pidStr) else { return }
            let appAX = AXUIElementCreateApplication(pid)
            let r1 = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let r2 = AXUIElementSetAttributeValue(appAX, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            try? "axenable \(pid): manual=\(r1.rawValue) enhanced=\(r2.rawValue)".write(toFile: "/tmp/switch_debug_capture.txt", atomically: true, encoding: .utf8)
        })
    }

    private static func runFocus(wid: CGWindowID, strategy: String) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let e = WindowEnumerator.enumerate(scope: .allWindows, frontmostPID: frontmost)
        let all = e.activeSpace + e.crossSpace
        guard let window = all.first(where: { $0.id == wid }) else {
            try? "{\"error\": \"wid \(wid) not found\"}".write(toFile: "/tmp/switch_debug_result.json", atomically: true, encoding: .utf8)
            return
        }
        switch strategy {
        case "current":       WindowFocuser.focus(window)
        // Step-by-step variants of the front-process path, to see which step loses the window.
        case "slps":          WindowFocuser.frontWindow(pid: window.pid, windowID: window.id)
        case "slps+act":
            WindowFocuser.frontWindow(pid: window.pid, windowID: window.id)
            WindowFocuser.cooperativeActivate(NSRunningApplication(processIdentifier: window.pid))
        case "act+slps":
            WindowFocuser.cooperativeActivate(NSRunningApplication(processIdentifier: window.pid))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WindowFocuser.frontWindow(pid: window.pid, windowID: window.id) }
        case "cached":
            if let ax = stash[wid] {
                AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                let appAX = AXUIElementCreateApplication(window.pid)
                AXUIElementSetAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, ax)
                NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
            } else {
                try? "{\"error\": \"no cached ax for \(wid)\"}".write(toFile: "/tmp/switch_debug_result.json", atomically: true, encoding: .utf8)
                return
            }
        case "setfs":
            if let ax = stash[wid] {
                AXUIElementSetAttributeValue(ax, "AXFullScreen" as CFString, kCFBooleanTrue)
            }
        case "menu":
            let ok = WindowFocuser.focusViaWindowMenu(window)
            if !ok {
                try? "{\"error\": \"no menu item matched\"}".write(toFile: "/tmp/switch_debug_result.json", atomically: true, encoding: .utf8)
                return
            }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dump(to: "/tmp/switch_debug_result.json", focusedWid: wid, strategy: strategy)
        }
    }

    /// AX elements captured while their windows were on the active Space.
    /// Remote AX handles stay valid after the window leaves the Space; this is
    /// how AltTab can raise windows Chromium no longer enumerates.
    nonisolated(unsafe) static var stash: [CGWindowID: AXUIElement] = [:]

    static func capture(pid: pid_t) {
        let appAX = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return }
        for ax in axWindows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(ax, &wid) == .success, wid != 0 {
                stash[wid] = ax
            }
        }
        try? "captured \(axWindows.count) for \(pid), stash now \(stash.count)".write(toFile: "/tmp/switch_debug_capture.txt", atomically: true, encoding: .utf8)
    }

    /// Dump an app's AX window list (wid, title, fullscreen, minimized) so we can
    /// see what Chromium actually exposes for cross-Space windows.
    private static func axDump(pid: pid_t) {
        let appAX = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        var rows: [[String: Any]] = []
        let err = AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref)
        if err == .success, let axWindows = ref as? [AXUIElement] {
            for ax in axWindows {
                var wid: CGWindowID = 0
                let widErr = _AXUIElementGetWindow(ax, &wid)
                var fsRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ax, "AXFullScreen" as CFString, &fsRef)
                var minRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minRef)
                rows.append([
                    "wid": Int(wid), "widErr": widErr.rawValue,
                    "title": AXHelpers.title(of: ax),
                    "fullscreen": (fsRef as? Bool) ?? false,
                    "minimized": (minRef as? Bool) ?? false,
                ])
            }
        }
        let out: [String: Any] = ["pid": Int(pid), "axErr": err.rawValue, "windows": rows]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/switch_debug_ax.json"))
        }
    }

    /// Screenshot of a screen region (win-tab holds Screen Recording, the shell doesn't).
    private static func shot(_ rect: CGRect) {
        guard let cg = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/switch_shot.png"))
    }

    /// Every Dock item as win-tab's DockAX reads it, plus the currently hovered one.
    private static func dockDump() {
        let rows: [[String: Any]] = DockAX.items().map { i in
            let f = i.frame ?? .zero
            return ["title": i.title, "subrole": i.subrole, "bundleID": i.bundleID ?? "", "badge": i.badge ?? "",
                    "frame": [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)], "running": i.runningApp != nil]
        }
        let hovered = DockAX.dockPID.flatMap { DockAX.list(dockPID: $0) }.flatMap { DockAX.hoveredItem(in: $0) }?.title ?? ""
        let stats = MainActor.assumeIsolated { DockController.debugStats.mapValues { "\($0)" } }
        let out: [String: Any] = ["items": rows, "hovered": hovered, "badges": DockAX.badges(), "controller": stats]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/switch_debug_dock.json"))
        }
    }

    struct SpaceWindowRecord { let parent: UInt32; let tags: UInt64; let attributes: UInt64 }

    /// Every top-level window the WindowServer files under the given Spaces, with its tags/attributes.
    private static func spaceWindowRecords(cid: CGSConnectionID, spaces: [Int]) -> [CGWindowID: SpaceWindowRecord] {
        guard !spaces.isEmpty else { return [:] }
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        let spaceArray = spaces.map { NSNumber(value: $0) } as CFArray
        guard let windows = SLSCopyWindowsWithOptionsAndTags(cid, 0, spaceArray, 0x7, &setTags, &clearTags)?.takeRetainedValue(),
              let query = SLSWindowQueryWindows(cid, windows, Int32(CFArrayGetCount(windows)))?.takeRetainedValue(),
              let iterator = SLSWindowQueryResultCopyWindows(query)?.takeRetainedValue() else { return [:] }
        var out: [CGWindowID: SpaceWindowRecord] = [:]
        while SLSWindowIteratorAdvance(iterator) {
            out[SLSWindowIteratorGetWindowID(iterator)] = SpaceWindowRecord(
                parent: SLSWindowIteratorGetParentID(iterator),
                tags: SLSWindowIteratorGetTags(iterator),
                attributes: SLSWindowIteratorGetAttributes(iterator)
            )
        }
        return out
    }

    /// Every layer-0 CG window of a regular app with its Spaces and WindowServer tags/attributes.
    private static func slsDump() {
        let cid = CGSMainConnectionID()
        let displays = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] ?? []
        let spaceIDs = displays.flatMap { ($0["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["id64"] as? Int } }
        let records = spaceWindowRecords(cid: cid, spaces: spaceIDs)
        let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var rows: [[String: Any]] = []
        for d in raw where (d[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
                  let wid = d[kCGWindowNumber as String] as? CGWindowID else { continue }
            let b = d[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let spaces = CGSCopySpacesForWindows(cid, 7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue() as? [Int] ?? []
            var row: [String: Any] = [
                "wid": Int(wid), "app": d[kCGWindowOwnerName as String] as? String ?? "",
                "title": d[kCGWindowName as String] as? String ?? "",
                "onscreen": d[kCGWindowIsOnscreen as String] as? Bool ?? false,
                "size": "\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))", "spaces": spaces,
            ]
            if let r = records[wid] {
                row["tags"] = String(r.tags, radix: 16); row["attrs"] = String(r.attributes, radix: 16); row["parent"] = Int(r.parent)
            }
            rows.append(row)
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/switch_debug_sls.json"))
        }
    }

    private static func dump(to path: String, focusedWid: CGWindowID? = nil, strategy: String? = nil) {
        let cid = CGSMainConnectionID()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let all = WindowEnumerator.enumerate(scope: .allWindows, frontmostPID: frontmost?.processIdentifier)
        func encode(_ w: WindowInfo) -> [String: Any] {
            [
                "wid": Int(w.id), "pid": Int(w.pid), "app": w.appName, "title": w.title,
                "crossSpace": w.isCrossSpace, "fullscreenSpace": w.isFullscreenSpace,
                "space": w.spaceLabel ?? "", "minimized": w.isMinimized, "hidden": w.isHidden,
            ]
        }
        var out: [String: Any] = [
            "activeSpace": Int(CGSGetActiveSpace(cid)),
            "frontmostApp": frontmost?.localizedName ?? "",
            "frontmostPID": Int(frontmost?.processIdentifier ?? 0),
            "activeSpaceWindows": all.activeSpace.map(encode),
            "crossSpaceWindows": all.crossSpace.map(encode),
        ]
        if let focusedWid { out["requestedWid"] = Int(focusedWid) }
        if let strategy { out["strategy"] = strategy }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
/// Counts display-link frames on the main thread over a window; a long gap between two frames
/// is a hitch the user sees as a stutter. Appends a line to /tmp/switch_debug_frames.txt.
@MainActor
final class FrameMeter: NSObject {
    static let shared = FrameMeter()
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var label = ""

    func measure(seconds: Double, label: String, action: () -> Void) {
        guard link == nil, let screen = NSScreen.screens.first else { return }
        self.label = label
        stamps = []
        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish() }
    }

    @objc private func tick(_ link: CADisplayLink) { stamps.append(CACurrentMediaTime()) }

    private func finish() {
        link?.invalidate()
        link = nil
        let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        let frame = NSScreen.screens.first.map { 1000.0 / Double($0.maximumFramesPerSecond) } ?? 16.7
        let hitches = gaps.filter { $0 > frame * 1.5 }
        // Where the long ones fall, in ms from the start (open vs. selection steps).
        let start = stamps.first ?? 0
        let long = zip(stamps.dropFirst(), gaps).filter { $0.1 > 20 }.map { String(format: "%.0f@%.0f", $0.1, ($0.0 - start) * 1000) }
        let line = String(format: "%@ frames=%d frame=%.1fms max=%.1fms hitches=%d sum_hitch=%.0fms long=%@\n",
                          label, stamps.count, frame, gaps.max() ?? 0, hitches.count, hitches.reduce(0, +), long.joined(separator: ","))
        if let h = FileHandle(forWritingAtPath: "/tmp/switch_debug_frames.txt") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            try? line.write(toFile: "/tmp/switch_debug_frames.txt", atomically: true, encoding: .utf8)
        }
    }
}
#endif
