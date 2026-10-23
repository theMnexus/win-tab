import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Under the SwiftUI lifecycle NSApp.delegate is SwiftUI's own wrapper, so casting it to AppDelegate finds nothing (#127).
    private(set) static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    private var model: SwitchModel?
    private var hotkey: HotkeyManager?
    private var window: SwitcherWindow?
    private var statusBar: StatusBarController?
    private var onboardingModel: OnboardingModel?
    private var onboardingWindow: NSWindow?
    private var focusTracker: FocusTracker?
    private var dockController: DockController?
    private var customDock: CustomDockController?
    private var notch: NotchController?
    private var batteryMenuBar: BatteryMenuBar?
    private var hotkeyStarted = false
    private var focusTrackerStarted = false
    #if DEBUG
    private let debugHarness = DebugFocusHarness()
    private var debugObservers: [NSObjectProtocol] = []
    #endif
    private var permsTimer: Timer?
    private var armedWatchdog: Timer?
    private var clickAwayMonitor: Any?
    private var pendingPresent: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        #if DEBUG
        debugHarness.start()
        #endif

        let model = SwitchModel()
        // Warm the windowless-app list so the first ⌘-Tab already has it.
        SwitchModel.refreshRegularApps()
        let window = SwitcherWindow(model: model)
        let hotkey = HotkeyManager()
        // The tap thread checks this to tell a stale arm (missed key release) from a live one.
        model.$visible
            .sink { [weak hotkey] in hotkey?.setPickerShown($0) }
            .store(in: &cancellables)

        // Most tap callbacks force a pending picker onto screen before acting.
        let present: () -> Void = { [weak self] in self?.presentNowIfPending(window: window) }

        hotkey.onArm = { [weak self] style in
            model.arm(style)
            self?.schedulePresent(window: window)
        }
        hotkey.onAdvance = { reverse in
            present()
            model.advance(reverse: reverse)
        }
        // Tap-originated commits already cleared armed on the tap thread; clearing again here races a fresh arm.
        hotkey.onCommit = { [weak self, weak model, weak window] quick in
            self?.cancelPendingPresent()
            model?.commit(stickyQuickTap: quick)
            window?.dismiss()
        }
        model.commitAndDismiss = { [weak self, weak model, weak window] in
            self?.cancelPendingPresent()
            self?.hotkey?.clearArmed()
            model?.commit()
            window?.dismiss()
        }
        hotkey.onCancel = { [weak self, weak model, weak window] in
            self?.cancelPendingPresent()
            model?.cancel()
            window?.dismiss()
        }
        let cancelAndDismiss: () -> Void = { [weak self, weak model, weak window] in
            self?.cancelPendingPresent()
            self?.hotkey?.clearArmed()
            model?.cancel()
            window?.dismiss()
        }
        model.cancelAndDismiss = cancelAndDismiss
        hotkey.onCloseSelected = { present(); model.closeSelected() }
        hotkey.onCloseSelectedApp = { present(); model.closeSelectedApp() }
        hotkey.onHideSelected = { present(); model.hideSelected() }
        hotkey.onNavigate = { present(); model.navigate(direction: $0) }
        hotkey.onPickIndex = { present(); model.pickIndex($0) }
        hotkey.onPickSelectOnly = { present(); model.selectIndex($0) }
        hotkey.onFilterAppend = { present(); model.appendFilter($0) }
        hotkey.onFilterBackspace = { present(); model.backspaceFilter() }
        #if DEBUG
        // Opens the picker and leaves it alone (as while the mouse moves over it), measuring frames.
        debugObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("switch.debug.switcherhold"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                FrameMeter.shared.measure(seconds: 4.5, label: "hold") {
                    model.arm(HotkeyManager.ArmStyle(mode: .allWindows))
                    window.present()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) { model.cancel(); window.dismiss() }
            }
        })
        // Opens the picker and sweeps in-app mouseMoved events across it at 120 Hz (no system
        // input, the real cursor stays put), measuring frames and how often the selection moved.
        debugObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("switch.debug.switcherhover"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                model.arm(HotkeyManager.ArmStyle(mode: .allWindows))
                window.present()
                var changes = 0
                var last = model.selected
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    FrameMeter.shared.measure(seconds: 2.0, label: "hover") {}
                    let b = window.contentView?.bounds ?? .zero
                    for step in 0..<240 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) / 120) {
                            let t = CGFloat(step) / 240
                            let p = NSPoint(x: b.minX + 40 + (b.width - 80) * t, y: b.maxY - 120 - (b.height - 240) * t)
                            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                                window.sendEvent(e)
                            }
                            if model.selected != last { changes += 1; last = model.selected }
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                        try? "hover selection changes=\(changes)\n".write(toFile: "/tmp/switch_debug_hover.txt", atomically: true, encoding: .utf8)
                        model.cancel(); window.dismiss()
                    }
                }
            }
        })
        // Opens the picker, steps the selection a few times and cancels, measuring frame delivery.
        debugObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("switch.debug.switcheranim"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                FrameMeter.shared.measure(seconds: 1.6, label: "switcher") {
                    model.arm(HotkeyManager.ArmStyle(mode: .allWindows))
                    window.present()
                }
                for step in 1...6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(step) * 0.15) { model.advance(reverse: false) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { model.cancel(); window.dismiss() }
            }
        })
        #endif
        hotkey.onStickyToggle = {
            SwitchPreferences.shared.stickyMode.toggle()
        }
        hotkey.onTranslate = { [weak self] in
            MainActor.assumeIsolated {
                SelectionReader.read { text in
                    if let text { TranslateModel.shared.translate(text) }
                    self?.notch?.open(tab: .translate)
                }
            }
        }
        hotkey.onOCR = {
            MainActor.assumeIsolated { OCRCapture.run() }
        }
        OCRCapture.prewarm()
        hotkey.onFileDrop = { [weak self] in
            MainActor.assumeIsolated {
                FinderSelection.read { urls in
                    if let urls {
                        FileShelf.shared.add(urls)
                    } else {
                        FileShelf.shared.notice = "Allow win-tab to control Finder in Privacy & Security › Automation"
                    }
                }
                self?.notch?.openFiles()
            }
        }
        hotkey.onOpenSettings = {
            MainActor.assumeIsolated { SettingsWindow.shared.show() }
        }

        SwitchPreferences.shared.$appearance
            .sink { NSApp.appearance = $0.nsAppearance }
            .store(in: &cancellables)
        SwitchPreferences.shared.$verticalList
            .dropFirst()
            .sink { [weak window] _ in window?.applyContentSize() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$thumbnailHeight
            .dropFirst()
            .sink { [weak window] _ in window?.applyContentSize() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$maxListRows
            .dropFirst()
            .sink { [weak window] _ in window?.applyContentSize() }
            .store(in: &cancellables)
        SwitchPreferences.shared.$showThumbnails
            .dropFirst()
            .sink { [weak self, weak window] enabled in
                window?.applyContentSize()
                if enabled && CGPreflightScreenCaptureAccess() == false {
                    self?.showOnboarding()
                } else if self?.requiredPermissionsGranted == true {
                    self?.startHotkeyIfNeeded()
                    self?.startFocusTrackerIfNeeded()
                }
            }
            .store(in: &cancellables)
        SwitchPreferences.shared.$hideMenuBarIcon
            .dropFirst()
            .sink { [weak self] hidden in
                self?.statusBar?.setHidden(hidden)
            }
            .store(in: &cancellables)

        self.model = model
        self.hotkey = hotkey
        self.window = window
        self.statusBar = StatusBarController()
        self.onboardingModel = OnboardingModel()
        self.focusTracker = FocusTracker()

        NotificationCenter.default.addObserver(
            forName: HotkeyConfig.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hotkey?.reload()
        }

        // Show onboarding if any permission is missing; otherwise install the tap.
        if !requiredPermissionsGranted {
            showOnboarding()
        } else {
            startHotkeyIfNeeded()
            startFocusTrackerIfNeeded()
        }

        // Background poll: as soon as both are granted, install the tap.
        permsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.requiredPermissionsGranted {
                self.startHotkeyIfNeeded()
                self.startFocusTrackerIfNeeded()
                // Both started and idempotent from here: stop polling permissions every second.
                self.permsTimer?.invalidate()
                self.permsTimer = nil
            }
        }

        // Watchdog: armed with no panel visible and none pending means the tap
        // is consuming keystrokes for a picker that doesn't exist (the "keyboard
        // stops working until Switch quits" report). Clear it.
        armedWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                SecureInputWatch.check()
                guard let self, let hotkey = self.hotkey, let model = self.model else { return }
                guard hotkey.isArmed else { return }
                if !model.visible && self.pendingPresent == nil {
                    hotkey.clearArmed()
                } else if model.visible {
                    hotkey.recoverIfReleaseWasMissed()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .switchRecorderBegan, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.model?.visible == true { cancelAndDismiss() }
                self?.hotkey?.setSuspended(true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .switchRecorderEnded, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hotkey?.setSuspended(false)
        }

        // A click in another app while the picker floats (sticky mode) should
        // dismiss it; otherwise the panel lingers and the tap keeps eating keys.
        // Global monitors never see events routed to our own panel.
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model?.visible == true else { return }
                cancelAndDismiss()
            }
        }
    }

    // Relaunching while already running reopens Settings and restores the menu bar icon if it was dragged off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.setHidden(UserDefaults.standard.bool(forKey: SwitchPreferences.hideMenuBarIconKey))
        if requiredPermissionsGranted {
            SettingsWindow.shared.show()
        } else {
            showOnboarding()
        }
        return true
    }

    private var requiredPermissionsGranted: Bool {
        let thumbnailsEnabled = (UserDefaults.standard.object(forKey: SwitchPreferences.showThumbnailsKey) as? Bool) ?? true
        let screenCaptureOK = !thumbnailsEnabled || CGPreflightScreenCaptureAccess()
        return AXIsProcessTrusted() && screenCaptureOK
    }

    private func schedulePresent(window: SwitcherWindow) {
        pendingPresent?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
            self?.pendingPresent = nil
            window?.present()
        }
        pendingPresent = work
        let ms = (UserDefaults.standard.object(forKey: SwitchPreferences.pickerActivationDelayKey) as? Double) ?? SwitchPreferences.defaultPickerActivationDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000.0, execute: work)
    }

    private func presentNowIfPending(window: SwitcherWindow) {
        guard let pending = pendingPresent else { return }
        pending.cancel()
        pendingPresent = nil
        window.present()
    }

    private func cancelPendingPresent() {
        pendingPresent?.cancel()
        pendingPresent = nil
    }

    private func startHotkeyIfNeeded() {
        guard !hotkeyStarted else { return }
        hotkey?.start()
        hotkeyStarted = true
        WindowStore.shared.refresh()
        MainActor.assumeIsolated { model?.startPrewarm() }
    }

    private func startFocusTrackerIfNeeded() {
        guard !focusTrackerStarted else { return }
        focusTracker?.start()
        focusTrackerStarted = true
        MainActor.assumeIsolated {
            MissionControlWatch.shared.start()
            let dock = DockController()
            dock.start()
            dockController = dock
            let custom = CustomDockController(dock: dock)
            custom.start()
            customDock = custom
            let notch = NotchController()
            notch.start()
            self.notch = notch
            BatteryAlertCenter.shared.start()
            BatteryHistory.shared.start()
            NotificationFeed.shared.start()
            let batteryMenuBar = BatteryMenuBar()
            batteryMenuBar.start()
            self.batteryMenuBar = batteryMenuBar
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Give Apple's Dock back if win-tab's Dock was hiding it.
        SystemDockHider.restore()
        MainActor.assumeIsolated {
            NowPlayingMonitor.shared.shutdown()
            BatteryHistory.shared.save()
        }
    }

    private func showOnboarding() {
        guard let onboardingModel else { return }
        if onboardingWindow == nil {
            let host = NSHostingController(rootView: OnboardingView().environmentObject(onboardingModel))
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "win-tab"
            win.contentViewController = host
            win.center()
            win.isReleasedWhenClosed = false
            win.delegate = self
            onboardingWindow = win
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win == onboardingWindow else { return }
        onboardingModel?.stopPolling()
        onboardingWindow = nil
        let settingsOpen = MainActor.assumeIsolated { SettingsWindow.shared.isVisible }
        if !settingsOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

final class SwitcherWindow: NSPanel {
    private let model: SwitchModel

    init(model: SwitchModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let host = NSHostingView(rootView: SwitchView().environmentObject(model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        contentView = host
        applyContentSize()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseUp, event.buttonNumber == 2, model.visible,
           model.mode != .spaces,
           !UserDefaults.standard.bool(forKey: SwitchPreferences.disableMouseKey),
           let wid = model.pointerWindowID {
            model.closeWindow(withWindowID: wid)
            return
        }
        super.sendEvent(event)
    }

    func applyContentSize(for screen: NSScreen? = nil) {
        let list = model.filteredWindows
        let windowless = SwitchPreferences.compactsWindowless(mode: model.mode) ? list.filter(\.isWindowless).count : 0
        let fitted = SwitcherPanelSize.current(
            mode: model.mode,
            itemCount: list.count - windowless,
            windowlessCount: windowless,
            screen: screen
        )
        model.panelSize = CGSize(width: fitted.width, height: fitted.height)
        setContentSize(fitted)
    }

    func present() {
        // Re-asserted every present so the panel migrates across Spaces.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Our own pop-in below replaces AppKit's window animation.
        animationBehavior = .none
        contentView?.layer?.cornerRadius = StylePreferences.shared.windowRadius

        let screen = Self.pickerScreen()
        applyContentSize(for: screen)
        if let screen {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            ))
        }
        orderFrontRegardless()
        if !SwitchPreferences.shared.disableAnimations { popIn() }
    }

    /// Fades the picker in while it grows from 95% with a light spring. Core Animation runs it on
    /// the render server, so it stays smooth while SwiftUI lays out the list behind it.
    private func popIn() {
        guard let layer = contentView?.layer else { return }
        let speed = Float(max(SwitchPreferences.shared.animationSpeed, 0.1))
        let s: CGFloat = 0.95
        let size = layer.bounds.size
        // Scale about the centre: the layer's origin is a corner.
        let start = CATransform3DScale(CATransform3DMakeTranslation(size.width * (1 - s) / 2, size.height * (1 - s) / 2, 0), s, s, 1)
        let grow = CASpringAnimation(keyPath: "sublayerTransform")
        grow.fromValue = NSValue(caTransform3D: start)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.stiffness = 420
        grow.damping = 32
        grow.duration = grow.settlingDuration
        grow.speed = speed
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        fade.speed = speed
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "popIn.grow")
        layer.add(fade, forKey: "popIn.fade")
    }

    func dismiss() {
        orderOut(nil)
    }

    static func pickerScreen() -> NSScreen? {
        switch SwitchPreferences.shared.pickerDisplay {
        case .mouse:
            return mouseScreen()
        case .active:
            // NSScreen.main follows win-tab's own key window (it has none while you work in
            // another app), so it pinned the picker to the menu-bar display; with the focus on
            // another monitor the picker opened out of sight.
            return focusedScreen() ?? mouseScreen()
        case .primary:
            return NSScreen.screens.first
        }
    }

    private static func mouseScreen() -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.screens.first
    }

    /// The display holding the frontmost app's frontmost window: where you're typing.
    private static func focusedScreen() -> NSScreen? {
        if NSApp.isActive, let key = NSApp.keyWindow { return key.screen }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let dict = top[kCGWindowBounds as String] as? NSDictionary,
              let cg = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        // Window bounds are top-left origin on the primary display; NSScreen frames bottom-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let center = CGPoint(x: cg.midX, y: primaryTop - cg.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { $0.frame.intersection(CGRect(x: cg.minX, y: primaryTop - cg.maxY, width: cg.width, height: cg.height)).area
                < $1.frame.intersection(CGRect(x: cg.minX, y: primaryTop - cg.maxY, width: cg.width, height: cg.height)).area }
    }
}

enum SwitcherPanelSize {
    static func current(mode: HotkeyManager.Mode, itemCount: Int, windowlessCount: Int = 0, screen: NSScreen?) -> NSSize {
        let defaults = UserDefaults.standard
        let isList = defaults.bool(forKey: SwitchPreferences.verticalListKey)
        let thumb = CGFloat((defaults.object(forKey: SwitchPreferences.thumbnailHeightKey) as? Double) ?? SwitchPreferences.defaultThumbnailHeight)
        let scale = thumb / CGFloat(SwitchPreferences.defaultThumbnailHeight)
        let count = max(itemCount, windowlessCount > 0 ? 0 : 1)
        // Every mode sizes to the window count; a fixed panel leaves rows of empty backdrop (#134).
        let size = (mode == .spaces || isList)
            ? listSize(defaults: defaults, count: count, windowless: windowlessCount, scale: scale, screen: screen)
            : gridSize(defaults: defaults, count: count, windowless: windowlessCount, thumb: thumb, scale: scale)
        return fit(size, on: screen)
    }

    static let slimRowHeight: CGFloat = 30

    private static func listSize(defaults: UserDefaults, count: Int, windowless: Int, scale: CGFloat, screen: NSScreen?) -> NSSize {
        let showHints = (defaults.object(forKey: SwitchPreferences.showHintStripKey) as? Bool) ?? true
        let showThumbs = (defaults.object(forKey: SwitchPreferences.showThumbnailsKey) as? Bool) ?? true
        let showPreview = ((defaults.object(forKey: SwitchPreferences.verticalShowPreviewKey) as? Bool) ?? true) && showThumbs
        let hintHeight: CGFloat = showHints ? 38 : 0
        let rowHeight: CGFloat = showPreview ? 62 : 48
        let chrome = 26 + hintHeight + 20
        let maxRows = (defaults.object(forKey: SwitchPreferences.maxListRowsKey) as? Int) ?? SwitchPreferences.defaultMaxListRows
        // Whole rows only: a screen-capped height leaves a clipped row at the bottom (#132).
        let fitting = screen.map { Int(($0.visibleFrame.height * 0.92 - chrome + 4) / (rowHeight + 4)) } ?? maxRows
        // Windowed rows first, then slim windowless rows, within the same row budget.
        let visibleRows = max(1, min(count + windowless, maxRows, fitting))
        let fullRows = min(count, visibleRows)
        let slimRows = visibleRows - fullRows
        let rowGaps = CGFloat(max(visibleRows - 1, 0)) * 4
        let height = chrome + CGFloat(fullRows) * rowHeight + CGFloat(slimRows) * slimRowHeight + rowGaps
        return NSSize(width: 520 * scale, height: max(260, height))
    }

    /// The compact strip of windowless apps under the tiles.
    static let stripChip = CGSize(width: 76, height: 70)
    static let stripSpacing: CGFloat = 6
    static let stripHeader: CGFloat = 22

    private static func gridSize(defaults: UserDefaults, count: Int, windowless: Int, thumb: CGFloat, scale: CGFloat) -> NSSize {
        let showHints = (defaults.object(forKey: SwitchPreferences.showHintStripKey) as? Bool) ?? true
        let showThumbs = (defaults.object(forKey: SwitchPreferences.showThumbnailsKey) as? Bool) ?? true
        let tileThumb: CGFloat = showThumbs ? thumb : SwitchPreferences.compactThumbnailHeight
        let configuredColumns = (defaults.object(forKey: SwitchPreferences.gridColumnsKey) as? Int) ?? SwitchPreferences.defaultGridColumns
        let columns = min(max(configuredColumns, 1), max(count, windowless > 0 ? configuredColumns : 3))
        let baseWidth: CGFloat = 880 * scale
        let horizontalPadding: CGFloat = 44
        let columnSpacing: CGFloat = 14
        let usable = baseWidth - horizontalPadding - CGFloat(max(configuredColumns - 1, 0)) * columnSpacing
        let columnWidth = usable / CGFloat(configuredColumns)
        let width = horizontalPadding + CGFloat(columns) * columnWidth + CGFloat(max(columns - 1, 0)) * columnSpacing

        let rows = Int(ceil(Double(count) / Double(columns)))
        let tileHeight = tileThumb + 52
        let rowsHeight = CGFloat(rows) * tileHeight + CGFloat(max(rows - 1, 0)) * 14
        let hintHeight: CGFloat = showHints ? 38 : 0
        var stripHeight: CGFloat = 0
        if windowless > 0 {
            let perRow = max(1, Int((width - horizontalPadding + stripSpacing) / (stripChip.width + stripSpacing)))
            let stripRows = Int(ceil(Double(windowless) / Double(perRow)))
            stripHeight = stripHeader + CGFloat(stripRows) * stripChip.height + CGFloat(stripRows - 1) * stripSpacing + (count > 0 ? 14 : 0)
        }
        let height = 26 + 16 + rowsHeight + stripHeight + hintHeight
        // The strip adds to the cap rather than scrolling out of view; fit() still keeps it on screen.
        return NSSize(width: max(560, width), height: min(560 * scale + stripHeight, max(320, height)))
    }

    private static func fit(_ size: NSSize, on screen: NSScreen?) -> NSSize {
        guard let screen else { return size }
        let visible = screen.visibleFrame
        return NSSize(
            width: min(size.width, visible.width * 0.92),
            height: min(size.height, visible.height * 0.92)
        )
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
