import AppKit
import ApplicationServices

/// Watches the Apple Dock (no injection): an AXObserver on its icon list reports the hovered
/// icon, which drives the window-preview panel; an event tap takes over clicks and scrolls on
/// icons when those options are on. Every behavior re-reads its preference, so toggles apply live.
@MainActor
final class DockController {
    private static let snapshotMaxAge: TimeInterval = 1
    private static let hideDelay: TimeInterval = 0.3
    private static let scrollInterval: TimeInterval = 0.3
    private static let healthInterval: TimeInterval = 3
    private static let pointerPollInterval: TimeInterval = 0.15
    private static let pointerMissesToHide = 2

    private let preview = DockPreviewPanel()
    private var observer: AXObserver?
    private var observedDockPID: pid_t?
    private var dockList: AXUIElement?
    private var hovered: DockAX.Item?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var eventTap: CFMachPort?
    private var healthTimer: Timer?
    private var healthGate = EnergySaver.Gate()
    private var pointerTimer: Timer?
    private var pointerMisses = 0
    private var scrollPosition: [pid_t: Int] = [:]
    private var lastScroll = Date.distantPast

    private var prefs: SwitchPreferences { .shared }

    /// Which Dock the hover card belongs to: Apple's (read over AX) or win-tab's own.
    private enum HoverSource {
        case system
        case custom(geometry: DockGeometry, pointerOnDock: () -> Bool)
    }
    private var source: HoverSource = .system

    #if DEBUG
    /// Read by the debug harness (dockdump).
    static var debugStats: [String: Any] = [:]
    #endif

    func start() {
        preview.model.onPick = { [weak self] window in
            self?.hidePreview()
            WindowFocuser.focus(window)
        }
        subscribe()
        installEventTap()
        healthTimer = Timer.scheduledTimer(withTimeInterval: Self.healthInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.healthGate.pass() else { return }
                self.checkHealth()
            }
        }
        healthTimer?.tolerance = Self.healthInterval * 0.1
    }

    // MARK: - Dock hover

    /// The Dock comes back with a new pid after `killall Dock` (Settings → Dock → Apply); re-attach.
    private func checkHealth() {
        if DockAX.dockPID != observedDockPID || dockList == nil { subscribe() }
        if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func subscribe() {
        unsubscribe()
        guard let pid = DockAX.dockPID, let list = DockAX.list(dockPID: pid) else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, dockSelectionCallback, &created) == .success, let obs = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(obs, list, kAXSelectedChildrenChangedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedDockPID = pid
        dockList = list
    }

    private func unsubscribe() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        observedDockPID = nil
        dockList = nil
        hovered = nil
    }

    fileprivate func dockSelectionChanged() {
        guard let list = dockList else { return }
        source = .system
        let item = DockAX.hoveredItem(in: list)
        requestCard(for: item, anchor: item?.frame)
    }

    /// Hover reports from win-tab's own Dock: same card, placed against that Dock.
    func customDockHover(_ item: DockAX.Item?, anchor: CGRect?, geometry: DockGeometry, pointerOnDock: @escaping () -> Bool) {
        source = .custom(geometry: geometry, pointerOnDock: pointerOnDock)
        requestCard(for: item, anchor: anchor)
    }

    private func requestCard(for item: DockAX.Item?, anchor: CGRect?) {
        hovered = item
        showWork?.cancel()
        guard let item, wantsCard(for: item), let anchor else {
            scheduleHide()
            return
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showCard(for: item, anchor: anchor) }
        showWork = work
        // Moving along the Dock with the card already up swaps it immediately; so does a card
        // covering Apple's name bubble, which the Dock shows without any delay.
        let delay = preview.isVisible || coversSystemLabel ? 0 : prefs.dockPreviewDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The card stands in for Apple's own name bubble (only Apple's Dock draws one).
    private var coversSystemLabel: Bool {
        if case .system = source { return prefs.dockReplaceLabels }
        return false
    }

    /// Apple's bubble centres on the magnified icon, while the AX frame read at hover time can
    /// still be the resting one; re-read it, and fall back to the pointer when it doesn't hold it.
    private func labelAnchor(for item: DockAX.Item, fallback: CGRect) -> CGRect {
        guard case .system = source else { return fallback }
        let fresh = item.element.flatMap(AXHelpers.frame(of:)) ?? fallback
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        let pointer = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        let vertical = geometry.edge.isVertical
        let holds = vertical ? (fresh.minY...fresh.maxY).contains(pointer.y) : (fresh.minX...fresh.maxX).contains(pointer.x)
        guard !holds else { return fresh }
        return vertical ? CGRect(x: fresh.minX, y: pointer.y - fresh.height / 2, width: fresh.width, height: fresh.height)
            : CGRect(x: pointer.x - fresh.width / 2, y: fresh.minY, width: fresh.width, height: fresh.height)
    }

    private var geometry: DockGeometry {
        if case let .custom(geometry, _) = source { return geometry }
        return .current
    }

    private var pointerOnSourceDock: Bool {
        if case let .custom(_, pointerOnDock) = source { return pointerOnDock() }
        return dockList.flatMap { DockAX.hoveredItem(in: $0) } != nil
    }

    /// With label replacement on, every labelled icon gets a card (it covers the Dock's own
    /// tooltip); otherwise only running apps do, for their window previews.
    private func wantsCard(for item: DockAX.Item) -> Bool {
        guard item.subrole != DockAX.separatorSubrole else { return false }
        if prefs.dockReplaceLabels { return true }
        return prefs.dockPreviews && item.runningApp != nil
    }

    private func showCard(for item: DockAX.Item, anchor: CGRect) {
        let app = item.runningApp
        let present: (WindowStore.Snapshot?) -> Void = { [weak self] snap in
            guard let self, let current = self.hovered, current.isSame(as: item) else { return }
            let appWindows = app.flatMap { a in snap.map { self.windows(of: a.processIdentifier, in: $0) } } ?? []
            let tiles = self.prefs.dockPreviews ? appWindows : []
            if tiles.isEmpty && !self.prefs.dockReplaceLabels { self.hidePreview(); return }
            let cover = self.coversSystemLabel
            self.preview.show(header: Self.header(for: item, app: app, windowCount: appWindows.count),
                              windows: tiles, anchor: cover ? self.labelAnchor(for: item, fallback: anchor) : anchor,
                              dock: self.geometry, coverLabel: cover)
            self.watchPointer()
        }
        let snap = WindowStore.shared.current
        present(snap)
        // Refresh only when stale: gliding along the Dock must not trigger a sweep per icon.
        if app != nil, (snap?.age ?? .infinity) > Self.snapshotMaxAge {
            WindowStore.shared.refresh { present($0) }
        }
    }

    private static func header(for item: DockAX.Item, app: NSRunningApplication?, windowCount: Int) -> DockPreviewModel.Header {
        let subtitle: String
        if !item.isApp {
            subtitle = ""
        } else if let app {
            if app.isHidden { subtitle = "Hidden" }
            else if windowCount == 0 { subtitle = "Running in background" }
            else { subtitle = windowCount == 1 ? "1 window" : "\(windowCount) windows" }
        } else {
            subtitle = "Not running"
        }
        let icon = app?.icon ?? item.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let badge = item.badge.flatMap { $0.isEmpty ? nil : $0 }
        return DockPreviewModel.Header(title: item.title, subtitle: subtitle, badge: badge, icon: icon)
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let item = self.hovered, self.wantsCard(for: item) { return }
            if self.preview.containsPointer { self.scheduleHide(); return }
            self.hidePreview()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }

    /// While the card is up, poll the pointer: hide once it's on neither the card nor a Dock
    /// icon. Covers a Dock that doesn't report leaving and card hover exits that never arrive.
    private func watchPointer() {
        guard pointerTimer == nil else { return }
        pointerMisses = 0
        pointerTimer = Timer.scheduledTimer(withTimeInterval: Self.pointerPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.preview.isVisible else { self.hidePreview(); return }
                // Two misses in a row, so crossing the gap between icon and card doesn't close it.
                self.pointerMisses = (self.pointerOnSourceDock || self.preview.containsPointer) ? 0 : self.pointerMisses + 1
                if self.pointerMisses >= Self.pointerMissesToHide {
                    self.hovered = nil // the Dock doesn't always report the pointer leaving
                    self.hidePreview()
                }
            }
        }
    }

    private func hidePreview() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        preview.hide()
    }

    private func windows(of pid: pid_t, in snap: WindowStore.Snapshot) -> [WindowInfo] {
        WindowMRU.sorted(snap.windows.allWindows.filter { $0.pid == pid }, frontmost: nil)
    }

    // MARK: - Clicks and scrolls on Dock icons

    private func installEventTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: dockEventCallback, userInfo: refcon) else {
            NSLog("win-tab: Dock event tap unavailable")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        eventTap = tap
        #if DEBUG
        Self.debugStats["tapInstalled"] = true
        #endif
    }

    /// The app icon under the pointer, re-read from the Dock at event time: with magnification
    /// the reported frames lag the enlarged icons, so the Dock's own selection is the truth.
    /// Only queried while a hover is in progress, so clicks elsewhere cost nothing.
    private func iconUnderPointer() -> (DockAX.Item, NSRunningApplication)? {
        guard hovered != nil, let list = dockList, let item = DockAX.hoveredItem(in: list),
              let app = item.runningApp else { return nil }
        return (item, app)
    }

    /// Returns true to swallow the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        #if DEBUG
        Self.debugStats["events"] = (Self.debugStats["events"] as? Int ?? 0) + 1
        Self.debugStats["lastEvent"] = "type=\(type.rawValue) at=\(event.location) hovered=\(hovered?.title ?? "nil") frame=\(String(describing: hovered?.frame))"
        #endif
        guard let (_, app) = iconUnderPointer() else { return false }
        switch type {
        case .leftMouseDown:
            hidePreview()
            guard prefs.dockClickToHide, app.isActive, !app.isHidden, hasVisibleWindow(app) else { return false }
            app.hide()
            return true
        case .scrollWheel:
            guard prefs.dockScrollCyclesWindows else { return false }
            let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            guard delta != 0 else { return true }
            guard Date().timeIntervalSince(lastScroll) >= Self.scrollInterval else { return true }
            lastScroll = Date()
            cycleWindows(of: app, forward: delta < 0)
            return true
        default:
            return false
        }
    }

    private func hasVisibleWindow(_ app: NSRunningApplication) -> Bool {
        WindowStore.shared.current?.windows.activeSpace.contains {
            $0.pid == app.processIdentifier && !$0.isMinimized && !$0.isHidden
        } ?? true
    }

    private func cycleWindows(of app: NSRunningApplication, forward: Bool) {
        guard let snap = WindowStore.shared.current else { return }
        let pid = app.processIdentifier
        let list = windows(of: pid, in: snap).sorted { $0.id < $1.id }
        guard !list.isEmpty else { return }
        let current = scrollPosition[pid] ?? -1
        let next = ((current + (forward ? 1 : -1)) % list.count + list.count) % list.count
        scrollPosition[pid] = next
        hidePreview()
        // Out of the tap callback: activation from inside it doesn't take.
        let target = list[next]
        DispatchQueue.main.async { WindowFocuser.focus(target) }
    }
}

// C callbacks: both sources run on the main run loop.

private func dockSelectionCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let controller = Unmanaged<DockController>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { controller.dockSelectionChanged() }
}

private func dockEventCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<DockController>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { controller.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
