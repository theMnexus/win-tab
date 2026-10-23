import AppKit
import Combine
import SwiftUI

/// Transparent panel above the menu bar holding one island. Clicks pass through while collapsed.
@MainActor
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        ignoresMouseEvents = true
        // Stationary: clicking the wallpaper (Show Desktop) pushes other windows to the screen
        // edges, and a transient island slid down to the bottom of the screen with them.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Only while typing a reply: the panel takes the keyboard without activating win-tab.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// A Dynamic Island on the notch (a pill on displays without one): hover it to open Now Playing,
/// the file Shelf, clipboard history and a timer; drag files onto it to shelve them.
///
/// Collapsed islands ignore the mouse, so the menu bar under them keeps working; pointer
/// movement is watched with global event monitors and the island only takes the mouse once open.
@MainActor
final class NotchController {
    private static let pollInterval: TimeInterval = 0.1
    /// Polls away before closing, from Settings → Notch → Close after.
    private var missesToCollapse: Int { max(1, Int((prefs.notchCloseDelay / Self.pollInterval).rounded())) }
    private static let popDuration: TimeInterval = 4
    private static let filesHold: TimeInterval = 6
    /// Pointer moves further than this below the top of the screen can't touch a closed island
    /// or its alert (the tallest alert is about 90 pt).
    private static let nearTop: CGFloat = 140
    /// How far the pointer can drift and still count as not moved (points).
    private static let pointerStill: CGFloat = 6

    @MainActor
    private final class Island {
        let panel: NotchPanel
        let state = NotchState()
        let geometry: NotchGeometry
        let screenFrame: CGRect
        /// Out of the way while an app is full screen on this display.
        var steppedAside = false
        var misses = 0
        /// A pop (timer finished) stays open at least this long even without the pointer.
        var holdUntil = Date.distantPast

        @MainActor
        init(screen: NSScreen) {
            geometry = NotchGeometry(screen: screen)
            screenFrame = screen.frame
            panel = NotchPanel(frame: geometry.panelFrame)
            panel.contentView = NotchIslandView(state: state, geometry: geometry)
            // Typing a reply: take the keyboard; done: give it back.
            replyWatch = state.$replying.removeDuplicates().sink { [weak panel] on in
                guard let panel else { return }
                panel.allowsKey = on
                if on { panel.makeKey() } else if panel.isKeyWindow { panel.resignKey() }
            }
            tabWatch = state.$tab.dropFirst().sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state.expanded else { return }
                    self.pointerAtTabChange = NSEvent.mouseLocation
                }
            }
        }
        private var replyWatch: AnyCancellable?
        private var tabWatch: AnyCancellable?
        /// Where the pointer was when a tab was clicked (see `poll`).
        var pointerAtTabChange: CGPoint?
    }

    private var islands: [Island] = []
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var fullScreenTimer: Timer?
    private var fullScreenGate = EnergySaver.Gate()
    private var spaceObservers: [NSObjectProtocol] = []
    private var pendingExpand: DispatchWorkItem?
    private var dragCountAtPress = NSPasteboard(name: .drag).changeCount
    private var prefs: SwitchPreferences { .shared }
    /// The running controller, for battery alerts.
    static weak var current: NotchController?
    private var alertGeneration = 0

    #if DEBUG
    /// The debug harness drives the island through this.
    static weak var debugShared: NotchController?
    var debugIsland: NotchIslandView? { islands.first?.panel.contentView as? NotchIslandView }
    var debugGeometry: NotchGeometry? { islands.first?.geometry }

    func debugOpen(tab: NotchTab) {
        guard let island = islands.first else { return }
        island.holdUntil = Date().addingTimeInterval(8)
        expand(island, tab: tab)
        island.state.tab = tab
    }

    func debugToggle() {
        guard let island = islands.first else { return }
        if island.state.expanded {
            island.holdUntil = .distantPast
            collapse(island)
        } else {
            island.holdUntil = Date().addingTimeInterval(3)
            expand(island, tab: .home)
        }
    }
    #endif

    func start() {
        Self.current = self
        #if DEBUG
        Self.debugShared = self
        #endif
        prefs.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] in self?.apply() }
            .store(in: &cancellables)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        NotchTimer.shared.onFinish = { [weak self] in self?.pop(.timer) }
        // Going full screen switches Space; a window can also grow to fill the display.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            spaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateFullScreen()
                    // The Space animation finishes a moment later.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self?.updateFullScreen() }
                }
            })
        }
        fullScreenTimer = Timer.scheduledTimer(withTimeInterval: Self.fullScreenInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.fullScreenGate.pass() else { return }
                self.updateFullScreen()
            }
        }
        fullScreenTimer?.tolerance = Self.fullScreenInterval * 0.1
        MissionControlWatch.shared.$isActive
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFullScreen(duration: 0.12) }
            .store(in: &cancellables)
        apply()
    }

    // MARK: - Full screen

    private static let fullScreenInterval: TimeInterval = 2.5

    /// Settings → Notch → Hide in full screen: an island fades out while another app's window
    /// fills its whole display, and comes back when that ends. Every island also steps aside
    /// while Mission Control is open.
    private func updateFullScreen(duration: TimeInterval = 0.2) {
        let missionControl = MissionControlWatch.shared.isActive
        let covered = prefs.notchEnabled && prefs.notchHideInFullScreen && !missionControl ? Self.filledScreens() : []
        for island in islands {
            let aside = missionControl || covered.contains(island.screenFrame)
            guard aside != island.steppedAside else { continue }
            island.steppedAside = aside
            if aside {
                pendingExpand?.cancel()
                pendingExpand = nil
                if island.state.expanded { collapse(island) }
                island.state.peeking = false
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                island.panel.animator().alphaValue = aside ? 0 : 1
            }
        }
    }

    /// Displays (AppKit frames) that another app's normal-level window covers edge to edge.
    private static func filledScreens() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let windows: [CGRect] = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict as CFDictionary)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map(\.frame).filter { f in
            // Window bounds are top-left based on the primary display.
            let target = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            return windows.contains { abs($0.minX - target.minX) < 1 && abs($0.minY - target.minY) < 1
                && abs($0.width - target.width) < 1 && abs($0.height - target.height) < 1 }
        }
    }

    // MARK: - State

    private static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    /// Displays that get an island. With no notched display (lid closed) the menu-bar display
    /// gets a pill, so the island never just disappears.
    private var wantedScreens: [NSScreen] {
        let screens = NSScreen.screens
        let main = screens.first.map { [$0] } ?? []
        switch prefs.notchDisplays {
        case .notched:
            let notched = screens.filter { $0.safeAreaInsets.top > 0 }
            return notched.isEmpty ? main : notched
        case .all: return screens
        case .main: return main
        case .mouse: return Self.screenUnderPointer().map { [$0] } ?? main
        case .chosen:
            let chosen = screens.filter { $0.localizedName == prefs.notchScreenName }
            return chosen.isEmpty ? main : chosen
        }
    }

    private func apply() {
        guard prefs.notchEnabled else {
            teardown()
            ClipboardHistory.shared.setActive(false)
            NowPlayingMonitor.shared.setActive(false, for: "notch")
            return
        }
        if islands.map(\.geometry.panelFrame) != wantedScreens.map({ NotchGeometry(screen: $0).panelFrame }) { rebuild() }
        NowPlayingMonitor.shared.setActive(true, for: "notch")
        ClipboardHistory.shared.setActive(prefs.notchClipboardHistory)
        installMonitors()
    }

    private func rebuild() {
        teardown()
        guard prefs.notchEnabled else { return }
        islands = wantedScreens.map(Island.init(screen:))
        islands.forEach { $0.panel.orderFrontRegardless() }
        updateFullScreen()
        installMonitors()
    }

    private func teardown() {
        islands.forEach { $0.panel.orderOut(nil) }
        islands = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func installMonitors() {
        guard monitors.isEmpty, !islands.isEmpty else { return }
        // Mouse-up too, so a swollen island settles when a file drag ends away from it.
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { monitors.append(m) }
        // A drag counts as a file drag only if the drag pasteboard changed since the press.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(m) }
    }

    // MARK: - Hover


    private func hotRect(_ island: Island) -> CGRect {
        island.geometry.rect(island.geometry.collapsedSize(wing: NotchActivity.wing(island.geometry))).insetBy(dx: -4, dy: -2)
    }

    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        // "Under the pointer": move the island to the display the pointer went to.
        if prefs.notchDisplays == .mouse, !islands.contains(where: \.state.expanded),
           let screen = Self.screenUnderPointer(), islands.first?.panel.screen?.frame != screen.frame {
            rebuild()
            return
        }
        let fileDrag = NSEvent.pressedMouseButtons & 1 != 0 && NSPasteboard(name: .drag).changeCount != dragCountAtPress
        for island in islands where !island.state.expanded && !island.steppedAside {
            // Most pointer moves are nowhere near the top of the screen (on the Dock, in a window):
            // skip them before working out the island's size.
            if p.y < island.screenFrame.maxY - Self.nearTop || !island.screenFrame.insetBy(dx: -1, dy: -1).contains(p) {
                if island.state.peeking { island.state.peeking = false }
                if island.state.dragNear { island.state.dragNear = false }
                continue
            }
            // A dodging alert (notifications) gets out of the way when the pointer comes near.
            if let alert = island.state.alert, alert.dodges,
               island.geometry.rect(island.geometry.alertSize(alert.style ?? .expanded)).insetBy(dx: -12, dy: -12).contains(p) {
                island.state.alert = nil
            }
            // A file on its way: swell early so the target is easy to hit, open once it's close.
            let near = fileDrag && hotRect(island).insetBy(dx: -90, dy: -60).contains(p)
            if island.state.dragNear != near { island.state.dragNear = near }
            let inside = hotRect(island).insetBy(dx: fileDrag ? -40 : 0, dy: fileDrag ? -24 : 0).contains(p)
            if island.state.peeking != inside { island.state.peeking = inside }
            guard inside else { continue }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                // Dragging something over the notch: open onto the Shelf so it can be dropped.
                if fileDrag { expand(island, tab: .shelf) }
                return
            }
            // With click-to-open, hovering only swells the island.
            guard !prefs.notchOpenOnClick, pendingExpand == nil else { return }
            let work = DispatchWorkItem { [weak self, weak island] in
                guard let self, let island else { return }
                self.pendingExpand = nil
                if self.hotRect(island).contains(NSEvent.mouseLocation) { self.expand(island, tab: nil) }
            }
            pendingExpand = work
            DispatchQueue.main.asyncAfter(deadline: .now() + prefs.notchHoverDelay, execute: work)
            return
        }
    }

    private func mouseDown() {
        dragCountAtPress = NSPasteboard(name: .drag).changeCount
        guard prefs.notchOpenOnClick else { return }
        let p = NSEvent.mouseLocation
        if let island = islands.first(where: { !$0.state.expanded && !$0.steppedAside && hotRect($0).contains(p) }) { expand(island, tab: nil) }
    }

    private func expand(_ island: Island, tab: NotchTab?) {
        if let tab { island.state.tab = tab }
        guard !island.state.expanded else { return }
        FileShelf.shared.prune()
        island.misses = 0
        island.state.peeking = false
        island.state.dragNear = false
        island.state.alert = nil
        island.state.expanded = true
        island.panel.ignoresMouseEvents = false
        if prefs.notchHaptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        NowPlayingMonitor.shared.setSourcesVisible(true)
        startPolling()
    }

    private func collapse(_ island: Island) {
        island.state.expanded = false
        if !islands.contains(where: { $0 !== island && $0.state.expanded }) { NowPlayingMonitor.shared.setSourcesVisible(false) }
        island.state.dropTargeted = false
        island.state.replying = false
        island.panel.ignoresMouseEvents = true
    }

    /// While open, poll the pointer: our own panel's moves never reach the global monitor.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let p = NSEvent.mouseLocation
        for island in islands where island.state.expanded {
            // Just clicked a tab: its bar may have moved away from a pointer that hasn't moved; stay
            // open until the pointer moves, then the usual rule applies.
            if let pin = island.pointerAtTabChange, hypot(p.x - pin.x, p.y - pin.y) > Self.pointerStill { island.pointerAtTabChange = nil }
            let inside = island.geometry.openRect(for: island.state.tab).insetBy(dx: -10, dy: -10).contains(p) || island.pointerAtTabChange != nil
            // Mid-reply, mid-resize or with a sheet up (Translate's language download) it stays open
            // even if the pointer wanders off.
            let held = Date() < island.holdUntil || island.state.dropTargeted || island.state.replying || island.state.resizing
                || island.panel.attachedSheet != nil
            island.misses = inside || held ? 0 : island.misses + 1
            if island.misses >= missesToCollapse { collapse(island) }
        }
        if !islands.contains(where: \.state.expanded) {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Shows `alert` on the closed island of the pointer's display for `duration` seconds. False
    /// when there's no island to show it on (off, or stepped aside for full screen).
    /// Rebuilds the islands if their size changed (e.g. the Notifications tab's height).
    func refreshLayout() { apply() }

    /// A nil `duration` keeps it until the island is opened.
    /// Shows on the islands of Settings → Notch → Alerts show on, all in the same run-loop turn so
    /// they animate together. False when none of those displays has an island to show it on.
    func present(_ alert: NotchAlert, duration: TimeInterval?) -> Bool {
        let wanted = prefs.alertScreens.map(\.frame)
        let targets = islands.filter { island in !island.steppedAside && wanted.contains { $0 == island.screenFrame } }
        guard !targets.isEmpty else { return false }
        alertGeneration += 1
        let mine = alertGeneration
        targets.forEach { $0.state.alert = alert }
        guard let duration else { return true }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.alertGeneration == mine else { return }
            targets.forEach { if $0.state.alert == alert { $0.state.alert = nil } }
        }
        return true
    }

    /// Opens the island on the pointer's display (or the first) for a moment, e.g. a timer ending.
    private func pop(_ tab: NotchTab) {
        let mouse = NSEvent.mouseLocation
        guard let island = islands.first(where: { NSMouseInRect(mouse, $0.panel.screen?.frame ?? .zero, false) }) ?? islands.first else { return }
        island.holdUntil = Date().addingTimeInterval(Self.popDuration)
        expand(island, tab: tab)
    }

    /// ⌃⌥D: the Files tab on the pointer's display, held open long enough to drag files in.
    func openFiles() { open(tab: .shelf) }

    /// A tab on the pointer's display (switched on if it was off), held open for a moment.
    func open(tab: NotchTab) {
        if !prefs.notchTabs.contains(tab.rawValue) { prefs.notchTabs.insert(tab.rawValue) }
        let mouse = NSEvent.mouseLocation
        let visible = islands.filter { !$0.steppedAside }
        guard let island = visible.first(where: { NSMouseInRect(mouse, $0.screenFrame, false) }) ?? visible.first else { return }
        island.holdUntil = Date().addingTimeInterval(Self.filesHold)
        expand(island, tab: tab)
    }
}
