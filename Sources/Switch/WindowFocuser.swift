import AppKit
import ApplicationServices

enum WindowFocuser {
    static func focus(_ window: WindowInfo) {
        if window.isWindowless {
            let app = NSRunningApplication(processIdentifier: window.pid)
            if app?.isHidden == true { app?.unhide() }
            if let url = app?.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            } else {
                app?.activate(options: [])
            }
            return
        }
        // "Bring the window here" only between desktop Spaces. Fullscreen
        // windows own their Space and can't be moved into another one, and
        // moving a desktop window while standing on a fullscreen Space sucks
        // it INTO that Space. Any fullscreen involvement → go to the window.
        if window.isCrossSpace && !window.isFullscreenSpace {
            let cid = CGSMainConnectionID()
            let currentSpace = CGSGetActiveSpace(cid)
            if !isFullscreenSpace(currentSpace, cid: cid) {
                let ids = [NSNumber(value: window.id)] as CFArray
                CGSMoveWindowsToManagedSpace(cid, ids, currentSpace)
                // Exempt from the current-space-claim prune: if the raise below
                // fails, the moved window sits here off-screen with no AX element.
                WindowEnumerator.noteSwitchMovedWindow(window.id)
            }
        }

        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }

        // Front the app with exactly this window key. activate() alone lets the app pick
        // its own key window, which on multi-display setups lands on the wrong one (#57).
        // The activates below still run: they don't move key off the fronted window.
        frontWindow(pid: window.pid, windowID: window.id)

        // Same-Space targets get an early best-effort activate so slow AX apps
        // (Godot, #117) start coming forward before the raise calls below. The
        // late activate still runs; cross-Space skips this because the
        // focused-window write must steer activation first.
        if !window.isCrossSpace { cooperativeActivate(app) }

        let appAX = AXUIElementCreateApplication(window.pid)
        var axWindows = AXHelpers.windowList(of: appAX)
        #if DEBUG
        // Pretend the app refuses Accessibility, to exercise the no-element path.
        if UserDefaults.standard.bool(forKey: "switch.debug.noAX") { axWindows = [] }
        #endif
        var raised = false
        if let target = bestMatch(for: window, in: axWindows) {
            AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            // Focused-window steers which Space activate() lands on when the
            // app has windows across several Spaces (fullscreen Chrome).
            AXUIElementSetAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, target)
            raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
        }
        // No usable element (Chromium hiding off-Space windows + cold cache, or
        // a stale cached handle): let the app focus it via its own Window menu.
        if !raised && window.isCrossSpace {
            raised = focusViaWindowMenu(window)
        }

        if raised {
            cooperativeActivate(app)
        } else {
            // Nothing raised it: the app refuses Accessibility (a long-running Chrome answers
            // kAXErrorAPIDisabled) or has no element for it. Activating brings back the app's
            // last key window, and a front-process call made before that is overruled (another
            // Chrome profile's window never came up). Activate first, then name the window.
            cooperativeActivate(app)
            let pid = window.pid, id = window.id
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.refrontDelay) { frontWindow(pid: pid, windowID: id) }
        }
        reopenIfStillHidden(window, app: app)

        if UserDefaults.standard.bool(forKey: SwitchPreferences.moveCursorToWindowKey) { moveCursor(to: window.bounds) }
        WindowMRU.touch(window.id)
    }

    private static let reopenCheckDelay: TimeInterval = 0.5
    /// After activating, before naming the window: the activation has to land first.
    private static let refrontDelay: TimeInterval = 0.12

    /// Tray apps (Zalo, Telegram, Electron) keep a closed window listed but ordered out: raising and
    /// activating leave it hidden, they only re-show it on reopen, the event a Dock click sends.
    /// Fullscreen targets are skipped: the Space animation outlasts the check.
    private static func reopenIfStillHidden(_ window: WindowInfo, app: NSRunningApplication?) {
        guard !window.isFullscreenSpace, let url = app?.bundleURL else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + reopenCheckDelay) {
            guard !isOnScreen(window.id) else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
    }

    private static func isOnScreen(_ id: CGWindowID) -> Bool {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first
        return info?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    // Only when the target sits on a different display than the pointer (#151).
    private static func moveCursor(to bounds: CGRect) {
        guard let mouse = CGEvent(source: nil)?.location else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var mouseDisplay = CGDirectDisplayID(0), targetDisplay = CGDirectDisplayID(0), n: UInt32 = 0
        CGGetDisplaysWithPoint(mouse, 1, &mouseDisplay, &n)
        CGGetDisplaysWithPoint(center, 1, &targetDisplay, &n)
        if mouseDisplay != targetDisplay { CGWarpMouseCursorPosition(center) }
    }

    /// WindowServer path (as yabai/AltTab do): set the front process with a target window, then post
    /// the key-window event record so that window, not the app's last key window, becomes key.
    @discardableResult
    static func frontWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        var psn = ProcessSerialNumber()
        guard SLGetProcessForPID(pid, &psn) == noErr,
              _SLPSSetFrontProcessWithOptions(&psn, windowID, SLPSMode.userGenerated) == noErr else { return false }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = SLPSPostEventRecordTo(&psn, &bytes)
        return true
    }

    // macOS 26 cooperative activation ignores activate() from the active app; yield first (#90).
    static func cooperativeActivate(_ app: NSRunningApplication?, allWindows: Bool = false) {
        if let app, NSApp.isActive { NSApp.yieldActivation(to: app) }
        app?.activate(options: allWindows ? [.activateAllWindows] : [])
    }

    /// Last-resort cross-Space focus: press the app's Window-menu item whose
    /// title matches the target window. The menu bar stays AX-accessible even
    /// when the app hides off-Space windows from enumeration (Chromium), and
    /// the app's own handler does makeKeyAndOrderFront, so macOS performs the
    /// Space switch natively. Returns false when no item matched.
    @discardableResult
    static func focusViaWindowMenu(_ window: WindowInfo) -> Bool {
        guard !window.title.isEmpty else { return false }
        let appAX = AXUIElementCreateApplication(window.pid)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let bar = barRef else { return false }
        var menusRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &menusRef) == .success,
              let menus = menusRef as? [AXUIElement] else { return false }
        // Window/Help only; Chrome's History menu matches closed windows by title and pressing one reopens it (#115).
        for menuBarItem in menus.suffix(2).reversed() {
            var subRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(menuBarItem, kAXChildrenAttribute as CFString, &subRef) == .success,
                  let submenus = subRef as? [AXUIElement] else { continue }
            for submenu in submenus {
                var itemsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(submenu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
                      let items = itemsRef as? [AXUIElement] else { continue }
                for item in items where AXHelpers.title(of: item) == window.title {
                    if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
                        WindowMRU.touch(window.id)
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func isFullscreenSpace(_ space: CGSSpaceID, cid: CGSConnectionID) -> Bool {
        guard let displays = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return false }
        for display in displays {
            for s in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = s["id64"] as? Int, CGSSpaceID(id) == space {
                    return (s["type"] as? Int ?? 0) != 0
                }
            }
        }
        return false
    }

    /// Direct CGWindowID match via private SPI; falls back to the AXWindowCache
    /// element captured while the window was on-screen (Chromium apps hide
    /// off-Space windows from kAXWindowsAttribute entirely, so the live list
    /// misses exactly the windows that need cross-Space focusing). Bounds and
    /// title matching remain as last resorts; never `first`; raising an
    /// arbitrary sibling sends focus to the wrong window.
    private static func bestMatch(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        if let exact = axWindows.first(where: { AXHelpers.windowID(of: $0) == window.id }) {
            return exact
        }
        if let cached = AXWindowCache.element(for: window.id) {
            return cached
        }
        var bestByBounds: (element: AXUIElement, distance: CGFloat)?
        for ax in axWindows {
            guard let frame = AXHelpers.frame(of: ax) else { continue }
            let d = abs(frame.origin.x - window.bounds.origin.x)
                  + abs(frame.origin.y - window.bounds.origin.y)
                  + abs(frame.size.width  - window.bounds.size.width)
                  + abs(frame.size.height - window.bounds.size.height)
            if bestByBounds == nil || d < bestByBounds!.distance {
                bestByBounds = (ax, d)
            }
        }
        if let bestByBounds, bestByBounds.distance < 40 { return bestByBounds.element }
        return axWindows.first(where: { AXHelpers.title(of: $0) == window.title })
    }
}

enum AppCloser {
    static func close(_ window: WindowInfo) {
        NSRunningApplication(processIdentifier: window.pid)?.terminate()
    }
}

enum WindowCloser {
    @discardableResult
    static func close(_ window: WindowInfo) -> Bool { pressButton(window, attribute: kAXCloseButtonAttribute) }

    /// Presses the close button of every standard window the app has (the app keeps running).
    /// Returns the windows whose button press went through.
    @discardableResult
    static func closeAll(pid: pid_t) -> Set<CGWindowID> {
        var closed: Set<CGWindowID> = []
        for w in AXHelpers.windowList(of: AXUIElementCreateApplication(pid)) where AXHelpers.isStandardWindow(w) {
            var btn: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &btn) == .success, let btn,
                  AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString) == .success,
                  let id = AXHelpers.windowID(of: w) else { continue }
            closed.insert(id)
        }
        return closed
    }

    /// Close only the specific window, resolving its AX element the way focus does
    /// (live wid match, then AXWindowCache), never an arbitrary sibling. Returns
    /// false without acting when nothing resolves, so callers can decline to fall back.
    @discardableResult
    static func closeExact(_ window: WindowInfo) -> Bool {
        pressButton(window, attribute: kAXCloseButtonAttribute, exactOnly: true)
    }
}

enum WindowMinimizer {
    static func minimize(_ window: WindowInfo) { pressButton(window, attribute: kAXMinimizeButtonAttribute) }
}

enum WindowZoomer {
    static func zoom(_ window: WindowInfo) { pressButton(window, attribute: kAXZoomButtonAttribute) }
}

/// Press a stoplight button; `exactOnly` never falls back to a sibling window.
@discardableResult
private func pressButton(_ window: WindowInfo, attribute: String, exactOnly: Bool = false) -> Bool {
    let axWindows = AXHelpers.windowList(of: AXUIElementCreateApplication(window.pid))
    let exact = axWindows.first(where: { AXHelpers.windowID(of: $0) == window.id })
    let target = exactOnly
        ? exact ?? AXWindowCache.element(for: window.id)
        : exact
            ?? axWindows.first(where: { AXHelpers.title(of: $0) == window.title })
            ?? axWindows.first
    guard let target else { return false }
    var btnRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(target, attribute as CFString, &btnRef) == .success,
          let btnObj = btnRef else { return false }
    return AXUIElementPerformAction(btnObj as! AXUIElement, kAXPressAction as CFString) == .success
}

enum AXHelpers {
    static func title(of element: AXUIElement) -> String {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref)
        return ref as? String ?? ""
    }

    /// Standard document window or dialog, the kinds a switcher should list.
    static func isStandardWindow(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref)
        let subrole = ref as? String ?? ""
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    static func windowList(of appAX: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    /// AX position + size as a CGRect, or nil if either attribute is missing.
    /// Used to disambiguate windows when titles collide (e.g. Chrome).
    static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        guard let posObj = posRef, let sizeObj = sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posObj as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeObj as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}

