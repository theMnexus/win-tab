import AppKit
import Combine
import SwiftUI

/// Borderless panel at Dock level, on every Space, never key.
@MainActor
final class CustomDockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
}

/// win-tab's own Dock: mirrors Apple's Dock apps, or shows your own arrangement (apps, groups,
/// folders, widgets, spacers, dividers). Sits on any screen edge, on the main display or on
/// every display, slides along the edge by dragging (and jumps to another edge when dragged
/// close to it), and shares the hover card.
@MainActor
final class CustomDockController {
    private static let refreshInterval: TimeInterval = 4
    private static let snapDistance: CGFloat = 90

    private let model = CustomDockModel()
    /// One panel per display the Dock shows on, paired by index with `screens`.
    private var panels: [CustomDockPanel] = []
    private var screens: [NSScreen] = []
    private let stack = DockStackPanel()
    private weak var dock: DockController?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var refreshGate = EnergySaver.Gate()
    private var iconCache: [String: NSImage] = [:]
    private var prefs: SwitchPreferences { .shared }

    #if DEBUG
    static weak var debugShared: CustomDockController?

    /// Opens the first group's grid (or closes it), for the debug harness.
    func debugToggleGroup() {
        guard let i = model.items.firstIndex(where: { if case .group = $0.content { return true }; return false }),
              let panel = panels.first else { return }
        openGroup(at: i, on: panel)
    }

    /// Drags every item (through the Dock's real mouse handlers) to the front and to the end,
    /// restoring the arrangement between tries.
    func debugDragAll(done: @escaping (String) -> Void) {
        let savedEntries = prefs.customDockEntries, savedOwn = prefs.customDockUseOwnItems
        guard let canvas = panels.first?.contentView as? CustomDockCanvas else { done("no canvas"); return }
        let titles = model.items.map { $0.title.isEmpty ? "[\($0.content)]" : $0.title }
        var lines = ["items: " + titles.joined(separator: " | ")]
        var tries: [(Int, String)] = []
        for i in titles.indices { tries.append((i, "front")); tries.append((i, "end")) }
        func restore() {
            prefs.customDockEntries = savedEntries
            prefs.customDockUseOwnItems = savedOwn
            reload()
            layoutPanels(animated: false)
        }
        func step(_ k: Int) {
            guard k < tries.count else {
                restore()
                if lines.count == 1 { lines.append("every drag landed") }
                done(lines.joined(separator: "\n"))
                return
            }
            let (i, where_) = tries[k]
            restore()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let key = { (item: CustomDockItem) in item.entryID?.uuidString ?? item.url?.path ?? item.id }
                let id = key(self.model.items[i])
                let ends = canvas.debugEnds
                canvas.debugDrag(from: i, toAlong: where_ == "front" ? ends.front : ends.end)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.reload()
                    let items = self.model.items
                    // Saved items keep their ids; a running app that got pinned is found by path.
                    let now = items.firstIndex { key($0) == id || ($0.url?.path != nil && $0.url?.path == self.model.items.first(where: { key($0) == id })?.url?.path) }
                        ?? items.firstIndex { $0.title == titles[i] }
                    let moved = where_ == "front" ? now == 0 : now.map { idx in !items[(idx + 1)...].contains { $0.entryID != nil } } ?? false
                    if !moved && !(i == 0 && where_ == "front") && titles[i] != "[divider]" {
                        lines.append("\(i) \(titles[i]) → \(where_): now at \(now.map(String.init) ?? "gone")/\(items.count)")
                    }
                    step(k + 1)
                }
            }
        }
        step(0)
    }

    /// Every item shown, one per line: index, title, content, saved or not, app path.
    func debugItems() -> String {
        panels.forEach { ($0.contentView as? CustomDockCanvas)?.conceal(false, slide: false, fade: false, duration: nil) }
        let windows = panels.map { "window \($0.windowNumber) \($0.frame) alpha \($0.alphaValue)" }
        return (windows + model.items.enumerated().map { i, item in
            "\(i)\t\(item.title.isEmpty ? "-" : item.title)\t\(item.content)\t\(item.entryID == nil ? "unsaved" : "saved")\t\(item.url?.path ?? "")\t\(item.id)"
        }).joined(separator: "\n")
    }

    /// Drops every movable item into the middle of the running apps and checks the Dock then
    /// reads in exactly the order it was dropped in (dividers aside). Restores the arrangement.
    func debugDropMiddle() -> String {
        let savedEntries = prefs.customDockEntries, savedOwn = prefs.customDockUseOwnItems
        func restore() { prefs.customDockEntries = savedEntries; prefs.customDockUseOwnItems = savedOwn; reload() }
        defer { restore() }
        restore()
        let name = { (item: CustomDockItem) in item.title }
        let isReal = { (item: CustomDockItem) -> Bool in item.content != .divider && !{ if case .trash = item.content { return true }; return false }() }
        guard let divider = model.items.firstIndex(where: { $0.id == "running-divider" }) else { return "no running apps to drop among" }
        let target = divider + max(1, (model.items.count - divider) / 2)
        var lines: [String] = []
        for i in model.items.indices {
            restore()
            guard canMove(i), i != target, i + 1 != target else { continue }
            var expected = model.items
            let moving = expected.remove(at: i)
            expected.insert(moving, at: target > i ? target - 1 : target)
            let want = expected.filter(isReal).map(name)
            drop(i, .insert(target))
            reload()
            let got = model.items.filter(isReal).map(name)
            if got != want { lines.append("\(moving.title): want \(want.joined(separator: ",")) got \(got.joined(separator: ","))") }
        }
        return lines.isEmpty ? "PASS: every item stays where it's dropped" : lines.joined(separator: "\n")
    }

    /// Tries moving every item to the front and to the end, then restores the arrangement.
    /// Reports items that can't be dragged or don't land where dropped.
    func debugMoveAll() -> String {
        let savedEntries = prefs.customDockEntries, savedOwn = prefs.customDockUseOwnItems
        defer {
            prefs.customDockEntries = savedEntries
            prefs.customDockUseOwnItems = savedOwn
            reload()
        }
        var lines: [String] = []
        let titles = model.items.map { $0.title.isEmpty ? "[\($0.content)]" : $0.title }
        lines.append("items: " + titles.joined(separator: " | "))
        for (i, title) in titles.enumerated() {
            prefs.customDockEntries = savedEntries
            prefs.customDockUseOwnItems = savedOwn
            reload()
            guard canMove(i) else { lines.append("\(i) \(title): not draggable"); continue }
            let id = model.items[i].url?.path ?? model.items[i].entryID?.uuidString
            for (label, at) in [("front", 0), ("end", model.items.count)] {
                prefs.customDockEntries = savedEntries
                prefs.customDockUseOwnItems = savedOwn
                reload()
                guard at != i, at != i + 1 else { continue }
                drop(i, .insert(at))
                reload()
                let now = model.items.firstIndex { ($0.url?.path ?? $0.entryID?.uuidString) == id || ($0.entryID != nil && $0.title == title) }
                let ok = label == "front" ? now == 0 : now.map { $0 >= model.items.count - 1 - model.items.filter({ $0.entryID == nil && $0.content != .app }).count } ?? false
                if !ok { lines.append("\(i) \(title) → \(label): landed at \(now.map(String.init) ?? "gone") of \(model.items.count)") }
            }
        }
        if lines.count == 1 { lines.append("all items move") }
        return lines.joined(separator: "\n")
    }
    #endif

    init(dock: DockController?) {
        self.dock = dock
        #if DEBUG
        Self.debugShared = self
        #endif
        stack.groupActions = .init(
            rename: { [weak self] in self?.renameGroup(id: $0, to: $1) },
            ungroup: { [weak self] in self?.ungroup(id: $0) },
            remove: { [weak self] in self?.removeFromGroup(id: $0, app: $1) },
            reorder: { [weak self] id, urls in
                self?.edit { $0 = $0.map { e in
                    guard e.id == id else { return e }
                    var copy = e
                    // Apps not shown (not installed right now) keep their place at the end.
                    let shown = urls.map(\.path)
                    copy.apps = shown + e.apps.filter { !shown.contains($0) }
                    return copy
                } }
            })
    }

    func start() {
        // A crash while hiding left Apple's Dock hidden; undo that unless it's still wanted.
        if SystemDockHider.isHiding && !(prefs.customDockEnabled && prefs.customDockHideSystemDock) {
            SystemDockHider.restore()
        }
        prefs.objectWillChange
            .merge(with: StylePreferences.shared.objectWillChange)
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] in self?.apply() }
            .store(in: &cancellables)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadIfEnabled() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        })
        // Mission Control shows Apple's Dock; ours would sit on top of it as a second one.
        MissionControlWatch.shared.$isActive
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                if active { self?.stack.close() }
                self?.layoutPanels(animated: false)
            }
            .store(in: &cancellables)
        apply()
    }

    // MARK: - State

    private func apply() {
        guard prefs.customDockEnabled else {
            panels.forEach { $0.orderOut(nil) }
            revealBars.forEach { $0.hide(animated: false, duration: 0) }
            stack.close()
            refreshTimer?.invalidate()
            refreshTimer = nil
            NowPlayingMonitor.shared.setActive(false, for: "dock")
            AttentionWatch.shared.stop()
            SystemDockHider.restore()
            return
        }
        AttentionWatch.shared.onChange = { [weak self] app, wants in self?.attention(app, wants: wants) }
        AttentionWatch.shared.start()
        reload()
        syncPanels()
        layoutPanels(animated: true)
        panels.forEach { $0.orderFrontRegardless() }
        if refreshTimer == nil {
            // Badges and running dots change without workspace notifications.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.refreshGate.pass() else { return }
                    self.reloadIfEnabled()
                }
            }
            refreshTimer?.tolerance = Self.refreshInterval * 0.1
        }
        if prefs.customDockHideSystemDock { SystemDockHider.hide() } else { SystemDockHider.restore() }
        updateAutoHide()
    }

    /// Apple's Dock as last read. Reading it over AX costs milliseconds per item, so it happens
    /// on a background queue (timer, app launches) and settings changes rebuild from this copy.
    private var dockItems: [DockAX.Item] = []
    private var fetching = false
    private let axQueue = DispatchQueue(label: "win-tab.customdock.ax", qos: .userInitiated)
    /// Summary of Apple's Dock as last applied (see `reloadIfEnabled`).
    private var dockKey = ""

    private func reloadIfEnabled() {
        // Nobody looking: badges and dots can wait until they're back. Mid-drag, rebuilding the
        // icons would shift the one being dragged; the next tick catches up.
        guard prefs.customDockEnabled, !fetching, !SystemActivity.userAway, !dragging else { return }
        fetching = true
        let showTrash = prefs.customDockShowTrash
        axQueue.async { [weak self] in
            let fresh = DockAX.items()
            // Summed up here, off the main thread: looking up each app's running state costs
            // milliseconds, and doing it on the main thread every few seconds made hovers stutter.
            let freshKey = fresh.map { "\($0.title)|\($0.url?.path ?? "")|\($0.badge ?? "")|\($0.subrole)|\($0.isRunning)" }.joined(separator: "\n")
            let trashFull = showTrash ? TrashBin.isFull : false
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                // Same apps, badges and running state as last time: nothing to rebuild.
                guard freshKey != self.dockKey || (showTrash && trashFull != self.trashFull) else { return }
                self.dockKey = freshKey
                self.dockItems = fresh
                let before = self.model.items.map(\.id)
                self.reload()
                if self.model.items.map(\.id) != before { self.layoutPanels(animated: true) }
            }
        }
    }

    /// Badges and running state always come from Apple's Dock (read over AX, which works even
    /// while it's hidden); the items are either its apps or your own arrangement.
    private func reload() {
        if dockItems.isEmpty { dockItems = DockAX.items() }
        let source = dockItems
        let items: [CustomDockItem]
        if prefs.customDockUseOwnItems {
            items = withTrash(ownItems(dockItems: source))
        } else {
            // An empty read means the Dock is restarting; keep what's shown.
            guard !source.isEmpty else { return }
            items = withTrash(source.filter(\.isApp).map { appItem(id: $0.url?.path ?? $0.title, entryID: nil, source: $0) })
        }
        // Apple's Dock can list one app twice for a moment (old and new process while it
        // relaunches or updates); the Dock tells slots apart by id, so show each id once.
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        if unique != model.items { model.items = unique }
        // Icons of apps no longer in the Dock (quit, unpinned) don't stay cached.
        let paths = Set(unique.flatMap { item -> [String] in
            switch item.content {
            case .group(let urls): return urls.map(\.path)
            case .folder(let url): return [url.path]
            default: return item.url.map { [$0.path] } ?? []
            }
        })
        if iconCache.keys.contains(where: { !paths.contains($0) }) { iconCache = iconCache.filter { paths.contains($0.key) } }
        NowPlayingMonitor.shared.setActive(unique.contains(where: \.showsNowPlaying), for: "dock")
    }

    private func ownItems(dockItems: [DockAX.Item]) -> [CustomDockItem] {
        var byPath: [String: DockAX.Item] = [:]
        for item in dockItems where item.isApp {
            if let path = item.url?.path { byPath[path] = item }
        }
        let fm = FileManager.default
        var items: [CustomDockItem] = []
        var pinned = Set<String>()
        for entry in prefs.customDockEntries {
            let id = entry.id.uuidString
            switch entry.kind {
            case .app:
                guard let path = entry.path, fm.fileExists(atPath: path) else { continue }
                pinned.insert(path)
                let url = URL(fileURLWithPath: path)
                let source = byPath[path] ?? .local(title: entry.title, url: url, subrole: DockAX.appItemSubrole)
                items.append(appItem(id: id, entryID: entry.id, source: source))
            case .folder:
                guard let path = entry.path else { continue }
                let url = URL(fileURLWithPath: path)
                items.append(CustomDockItem(id: id, title: entry.title, url: url, icon: icon(for: path), isRunning: false, badge: nil,
                                            content: .folder(url), entryID: entry.id,
                                            source: .local(title: entry.title, url: url, subrole: DockAX.folderSubrole)))
            case .group:
                let urls = entry.apps.filter { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
                // Grouped apps don't show again among the running apps; the group gets their dot.
                pinned.formUnion(entry.apps)
                let running = urls.contains { byPath[$0.path]?.isRunning == true }
                items.append(CustomDockItem(id: id, title: entry.title, url: nil, icon: NSImage(), isRunning: running, badge: nil,
                                            content: .group(urls), entryID: entry.id, groupIcons: urls.prefix(4).map { icon(for: $0.path) },
                                            source: .local(title: entry.title, url: nil, subrole: DockAX.folderSubrole)))
            case .spacer, .divider, .widget, .stack:
                let content: CustomDockItem.Content
                switch entry.kind {
                case .spacer: content = .spacer
                case .divider: content = .divider
                case .stack: content = .stack(entry.widgets ?? [])
                default: content = .widget(entry.widget ?? .clock)
                }
                items.append(CustomDockItem(id: id, title: entry.title, url: nil, icon: NSImage(), isRunning: false, badge: nil,
                                            content: content, entryID: entry.id,
                                            source: .local(title: entry.title, url: nil, subrole: "")))
            }
        }
        // Running apps you haven't pinned follow a divider, like on Apple's Dock.
        let running = dockItems.filter { $0.isApp && $0.isRunning && !pinned.contains($0.url?.path ?? "") }
        if !running.isEmpty {
            items.append(CustomDockItem(id: "running-divider", title: "", url: nil, icon: NSImage(), isRunning: false, badge: nil,
                                        content: .divider, source: .local(title: "", url: nil, subrole: "")))
            items += running.map { appItem(id: $0.url?.path ?? $0.title, entryID: nil, source: $0) }
        }
        return items
    }

    /// The Trash after a divider at the end (Settings → Dock → Show Trash).
    private func withTrash(_ items: [CustomDockItem]) -> [CustomDockItem] {
        guard prefs.customDockShowTrash else { return items }
        let full = TrashBin.isFull
        trashFull = full
        let local = DockAX.Item.local(title: "Trash", url: TrashBin.url, subrole: "")
        return items + [
            CustomDockItem(id: "trash-divider", title: "", url: nil, icon: NSImage(), isRunning: false, badge: nil, content: .divider, source: local),
            CustomDockItem(id: "trash", title: "Trash", url: nil, icon: TrashBin.icon(full: full), isRunning: false, badge: nil,
                           content: .trash(full: full), source: local),
        ]
    }
    private var trashFull = false

    private func appItem(id: String, entryID: UUID?, source: DockAX.Item) -> CustomDockItem {
        CustomDockItem(id: id, title: source.title, url: source.url,
                       icon: source.url.map { icon(for: $0.path) } ?? NSImage(),
                       isRunning: source.isRunning,
                       badge: source.badge.flatMap { $0.isEmpty ? nil : $0 }, content: .app, entryID: entryID, source: source)
    }

    private func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    // MARK: - Placement

    private static var primaryScreen: NSScreen? { NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main }
    private func edge(of screen: NSScreen?) -> ScreenEdge {
        screen.map { prefs.dockPlacement(for: $0).edge } ?? prefs.customDockEdge
    }

    private func layout(on screen: NSScreen?) -> CustomDockLayout {
        CustomDockLayout.make(prefs: prefs, items: model.items, edge: edge(of: screen))
    }

    private func layout(for panel: CustomDockPanel?) -> CustomDockLayout { layout(on: screen(of: panel)) }

    /// One panel per target display: the main one, or all of them, each on its display's edge.
    private func syncPanels() {
        screens = prefs.customDockAllDisplays ? NSScreen.screens : Self.primaryScreen.map { [$0] } ?? []
        while panels.count < screens.count {
            let i = panels.count
            panels.append(makePanel())
            revealBars.append(DockRevealBar { [weak self] in self?.reveal(i) })
        }
        while panels.count > screens.count {
            panels.removeLast().orderOut(nil)
            revealBars.removeLast().hide(animated: false, duration: 0)
        }
        for (panel, screen) in zip(panels, screens) {
            (panel.contentView as? CustomDockCanvas)?.edge = edge(of: screen)
        }
    }

    private func makePanel() -> CustomDockPanel {
        let panel = CustomDockPanel()
        panel.contentView = CustomDockCanvas(model: model, callbacks: .init(
            onHover: { [weak self, weak panel] in self?.hover($0, on: panel) },
            onClick: { [weak self, weak panel] in self?.click($0, on: panel) },
            onDragChanged: { [weak self, weak panel] in self?.dragChanged(on: panel) },
            onDragEnded: { [weak self] in
                self?.grab = nil
                self?.layoutPanels(animated: true)
            },
            canMove: { [weak self] in self?.canMove($0) ?? false },
            onDrop: { [weak self] in self?.drop($0, $1) },
            menuAt: { [weak self] in self?.menu(for: $0) ?? [] }
        ))
        return panel
    }

    private func screen(of panel: CustomDockPanel?) -> NSScreen? {
        panel.flatMap { p in panels.firstIndex { $0 === p } }.flatMap { screens.indices.contains($0) ? screens[$0] : nil }
    }

    /// Usable span: below the menu bar, full width otherwise.
    private func area(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: f.minY, width: f.width, height: screen.visibleFrame.maxY - f.minY)
    }

    /// The Dock's window, reaching to the screen edge across the margin (see `edgeGap`).
    private func frame(on screen: NSScreen) -> CGRect {
        let (edge, offset) = prefs.dockPlacement(for: screen)
        let size = layout(on: screen).panelSize, a = area(screen), m = CGFloat(prefs.customDockMargin)
        let t = CGFloat(offset)
        switch edge {
        case .bottom: return CGRect(x: a.minX + (a.width - size.width) * t, y: a.minY, width: size.width, height: size.height + m)
        case .top: return CGRect(x: a.minX + (a.width - size.width) * t, y: a.maxY - size.height - m, width: size.width, height: size.height + m)
        case .left: return CGRect(x: a.minX, y: a.maxY - size.height - (a.height - size.height) * t, width: size.width + m, height: size.height)
        case .right: return CGRect(x: a.maxX - size.width - m, y: a.maxY - size.height - (a.height - size.height) * t, width: size.width + m, height: size.height)
        }
    }

    /// Hidden state each panel was last placed in, to tell hide/show moves from ordinary ones.
    private var placedHidden: [Int: Bool] = [:]
    private var revealBars: [DockRevealBar] = []

    private func layoutPanels(animated: Bool) {
        guard prefs.customDockEnabled else { return }
        let style = prefs.customDockHideStyle
        let slides = style == .slide || style == .slideFade, fades = style == .fade || style == .slideFade
        let missionControl = MissionControlWatch.shared.isActive
        for (i, (panel, screen)) in zip(panels, screens).enumerated() {
            let canvas = panel.contentView as? CustomDockCanvas
            canvas?.edge = edge(of: screen)
            canvas?.edgeGap = CGFloat(prefs.customDockMargin)
            let isHidden = hidden.contains(i)
            let target = frame(on: screen)
            let toggling = placedHidden[i] != isHidden
            let firstPlacement = placedHidden[i] == nil
            placedHidden[i] = isHidden
            panel.ignoresMouseEvents = isHidden || missionControl
            if revealBars.indices.contains(i) {
                let barDuration = prefs.customDockHideDuration
                if isHidden && !missionControl { revealBars[i].show(edge: edge(of: screen), dock: target, screen: screen, animated: animated, duration: barDuration) }
                else { revealBars[i].hide(animated: animated, duration: barDuration * 0.5) }
            }
            // The window stays where the Dock shows; hiding only moves its layers.
            let alpha: CGFloat = missionControl ? 0 : 1
            if panel.alphaValue != alpha { panel.alphaValue = alpha }
            if toggling {
                let run = animated && panel.isVisible && !firstPlacement
                canvas?.conceal(isHidden, slide: slides, fade: fades, duration: run ? prefs.customDockHideDuration : nil)
            }
            guard target != panel.frame else { continue }
            guard animated, panel.isVisible, !isHidden else {
                panel.setFrame(target, display: true)
                continue
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    /// Brings a hidden Dock back (its reveal bar was hovered or clicked).
    private func reveal(_ i: Int) {
        guard hidden.contains(i) else { return }
        hidden.remove(i)
        hideWork?.cancel()
        hideWork = nil
        layoutPanels(animated: true)
    }

    /// Where the pointer grabbed the panel, so a drag moves the Dock by the handle instead of
    /// snapping its centre under the pointer.
    private var grab: CGPoint?

    /// Follow the pointer along the edge; near another edge, move there. Each display keeps its own place.
    private func dragChanged(on panel: CustomDockPanel?) {
        guard let panel, let screen = screen(of: panel) else { return }
        stack.close()
        let mouse = NSEvent.mouseLocation, a = area(screen)
        let grab = self.grab ?? CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        self.grab = grab
        let distances: [(ScreenEdge, CGFloat)] = [(.left, mouse.x - a.minX), (.right, a.maxX - mouse.x),
                                                   (.bottom, mouse.y - a.minY), (.top, a.maxY - mouse.y)]
        var edge = self.edge(of: screen)
        if let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < Self.snapDistance { edge = nearest.0 }
        let size = CustomDockLayout.make(prefs: prefs, items: model.items, edge: edge).panelSize
        // After jumping to another edge the old grab point may not fit; keep it inside the panel.
        let gx = min(grab.x, size.width), gy = min(grab.y, size.height)
        let offset: CGFloat = edge.isVertical
            ? (a.maxY - mouse.y - gy) / max(a.height - size.height, 1)
            : (mouse.x - a.minX - gx) / max(a.width - size.width, 1)
        prefs.setDockPlacement(edge, offset: Double(offset), for: screen)
        layoutPanels(animated: false)
    }

    // MARK: - Auto-hide

    /// Indexes of panels slid out of sight.
    private var hidden: Set<Int> = []
    private var hideWork: DispatchWorkItem?
    /// Items whose app is asking for attention (see `AttentionWatch`).
    private var attentionIDs: Set<String> = []

    /// An app asking for attention hops in this Dock; an auto-hidden Dock shows itself meanwhile,
    /// as Apple's does.
    private func attention(_ app: NSRunningApplication, wants: Bool, retried: Bool = false) {
        guard let url = app.bundleURL?.standardizedFileURL else { return }
        guard let item = model.items.first(where: { $0.url?.standardizedFileURL == url }) else {
            // Just launched: Apple's Dock list (read every few seconds) may not have it yet.
            if wants && !retried {
                reloadIfEnabled()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.attention(app, wants: wants, retried: true) }
            }
            return
        }
        if wants { attentionIDs.insert(item.id) } else { attentionIDs.remove(item.id) }
        panels.forEach { ($0.contentView as? CustomDockCanvas)?.setAttention(attentionIDs) }
        guard prefs.customDockAutoHide else { return }
        if wants, !hidden.isEmpty {
            hideWork?.cancel()
            hideWork = nil
            hidden = []
            layoutPanels(animated: true)
        } else if attentionIDs.isEmpty {
            autoHidePointerMoved()
        }
    }
    private var hideMonitors: [Any] = []
    /// While a Dock is hidden, the pointer is read on a timer: at the screen edge, mouse-moved events
    /// don't reliably reach the monitors or the reveal bar's own tracking area.
    private var edgePoll: Timer?
    private static let edgePollInterval: TimeInterval = 0.05

    private func watchEdge() {
        guard edgePoll == nil else { return }
        let timer = Timer(timeInterval: Self.edgePollInterval, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.hidden.isEmpty, self.prefs.customDockAutoHide else {
                    t.invalidate()
                    self?.edgePoll = nil
                    return
                }
                self.autoHidePointerMoved()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgePoll = timer
    }

    private func updateAutoHide() {
        guard prefs.customDockEnabled, prefs.customDockAutoHide else {
            hideMonitors.forEach(NSEvent.removeMonitor)
            hideMonitors = []
            hideWork?.cancel()
            if !hidden.isEmpty { hidden = []; layoutPanels(animated: true) }
            return
        }
        guard hideMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.autoHidePointerMoved() }
        }) { hideMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.autoHidePointerMoved()
            return event
        }) { hideMonitors.append(m) }
        hidden = Set(panels.indices)
        watchEdge()
        layoutPanels(animated: true)
    }

    /// Reveal a hidden Dock only when the pointer is on its reveal bar; hide a shown one a moment
    /// after the pointer leaves it (not while a group or folder grid is open).
    /// A drag in progress on any of the Docks.
    /// Only while the button is actually down, so a lost mouse-up can't stall auto-hide.
    private var dragging: Bool {
        NSEvent.pressedMouseButtons & 1 != 0 && panels.contains { ($0.contentView as? CustomDockCanvas)?.isDragging == true }
    }

    private func autoHidePointerMoved() {
        // Mid-drag the pointer often leaves the Dock (icons are dragged up and along); hiding then
        // turned off the Dock's mouse and the icon snapped back.
        if dragging {
            hideWork?.cancel()
            hideWork = nil
            return
        }
        let p = NSEvent.mouseLocation
        var changed = false
        for (i, panel) in panels.enumerated() {
            if hidden.contains(i) {
                guard revealBars.indices.contains(i), revealBars[i].hitFrame?.contains(p) == true else { continue }
                hidden.remove(i)
                changed = true
            } else if !panel.frame.insetBy(dx: -12, dy: -12).contains(p) && !stack.isVisible {
                scheduleHide(i)
            } else {
                hideWork?.cancel()
                hideWork = nil
            }
        }
        if changed { layoutPanels(animated: true) }
    }

    private func scheduleHide(_ i: Int) {
        guard hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            guard self.prefs.customDockAutoHide, self.panels.indices.contains(i) else { return }
            let p = NSEvent.mouseLocation
            guard !self.panels[i].frame.insetBy(dx: -12, dy: -12).contains(p), !self.stack.isVisible, !self.dragging,
                  self.attentionIDs.isEmpty else { return }
            self.hidden.insert(i)
            self.watchEdge()
            self.hover(nil, on: self.panels[i])
            self.layoutPanels(animated: true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + prefs.customDockAutoHideDelay, execute: work)
    }

    // MARK: - Interaction

    private var pointerOnDock: Bool {
        let mouse = NSEvent.mouseLocation
        return panels.indices.contains { !hidden.contains($0) && panels[$0].isVisible && panels[$0].frame.contains(mouse) }
    }

    private func geometry(on panel: CustomDockPanel?) -> DockGeometry {
        let edge = edge(of: screen(of: panel))
        var reach = CGFloat(prefs.customDockMargin) + layout(for: panel).panelThickness
        if edge == .top, let screen = screen(of: panel) { reach += screen.frame.maxY - screen.visibleFrame.maxY }
        return DockGeometry(edge: edge, reach: reach)
    }

    private func hover(_ index: Int?, on panel: CustomDockPanel?) {
        let geometry = geometry(on: panel)
        let pointerOnDock: () -> Bool = { [weak self] in self?.pointerOnDock ?? false }
        guard let index, model.items.indices.contains(index), let panel else {
            dock?.customDockHover(nil, anchor: nil, geometry: geometry, pointerOnDock: pointerOnDock)
            return
        }
        let item = model.items[index]
        switch item.content {
        case .app, .folder, .group:
            dock?.customDockHover(item.source, anchor: globalRect(layout(for: panel).itemRect(index), in: panel), geometry: geometry, pointerOnDock: pointerOnDock)
        case .spacer, .divider, .widget, .stack, .trash:
            dock?.customDockHover(nil, anchor: nil, geometry: geometry, pointerOnDock: pointerOnDock)
        }
    }

    /// Panel-local (top-left) rect to global AX coordinates (top-left of the primary display).
    private func globalRect(_ local: CGRect, in panel: CustomDockPanel) -> CGRect {
        let mainHeight = Self.primaryScreen?.frame.height ?? 0
        // Layout coordinates start past a top or left edge gap.
        let origin = panel.contentView?.bounds.origin ?? .zero
        return CGRect(x: panel.frame.minX + local.minX - origin.x, y: mainHeight - panel.frame.maxY + local.minY - origin.y,
                      width: local.width, height: local.height)
    }

    private func click(_ index: Int, on panel: CustomDockPanel?) {
        guard model.items.indices.contains(index), let panel else { return }
        let item = model.items[index]
        hover(nil, on: panel)
        let anchor = globalRect(layout(for: panel).itemRect(index), in: panel)
        switch item.content {
        case .app:
            stack.close()
            if let app = item.source.runningApp, app.isActive, !app.isHidden, prefs.dockClickToHide {
                app.hide()
                return
            }
            open(item)
        case .group:
            openGroup(at: index, on: panel)
        case .folder(let url):
            stack.toggle(title: item.title, entries: DockStackPanel.entries(folder: url), folder: url, anchor: anchor, dock: geometry(on: panel))
        case .widget(let kind):
            stack.close()
            openWidgetApp(kind)
        case .spacer, .divider, .stack:
            // A Smart Stack's own buttons and scrolling handle it.
            stack.close()
        case .trash:
            stack.close()
            TrashBin.open()
        }
    }

    /// Like a Dock click: launches, or activates and reopens (tray apps show their window).
    private func open(_ item: CustomDockItem) {
        guard let url = item.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    private func openWidgetApp(_ kind: DockWidgetKind) {
        let ws = NSWorkspace.shared
        switch kind {
        case .nowPlaying:
            // The playing app (the browser for a YouTube tab), or Music when nothing plays.
            if NowPlayingMonitor.shared.track != nil {
                NowPlayingMonitor.shared.openPlayer()
            } else if let url = ws.urlForApplication(withBundleIdentifier: "com.apple.Music") {
                ws.open(url)
            }
        case .clock:
            openApp("com.apple.clock", fallback: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension")
        case .calendar:
            openApp("com.apple.iCal")
        case .battery:
            openURL("x-apple.systempreferences:com.apple.Battery-Settings.extension")
        }
    }

    private func openApp(_ bundleID: String, fallback: String? = nil) {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            ws.openApplication(at: url, configuration: config, completionHandler: nil)
        } else if let fallback {
            openURL(fallback)
        }
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    /// Right-click actions for a widget: open its app and a few shortcuts.
    private func widgetActions(_ kind: DockWidgetKind) -> [CustomDockMenuAction] {
        switch kind {
        case .nowPlaying:
            let np = NowPlayingMonitor.shared
            var actions = [CustomDockMenuAction(title: np.track?.playing == true ? "Pause" : "Play") { np.send(.playpause) },
                           CustomDockMenuAction(title: "Next") { np.send(.next) },
                           CustomDockMenuAction(title: "Previous") { np.send(.previous) }]
            if let player = np.track?.player { actions.append(CustomDockMenuAction(title: "Open \(player)") { np.openPlayer() }) }
            return actions
        case .clock:
            return [CustomDockMenuAction(title: "Open Clock") { [weak self] in self?.openApp("com.apple.clock") },
                    CustomDockMenuAction(title: "Date & Time Settings…") { [weak self] in self?.openURL("x-apple.systempreferences:com.apple.Date-Time-Settings.extension") }]
        case .calendar:
            return [CustomDockMenuAction(title: "Open Calendar") { [weak self] in self?.openApp("com.apple.iCal") },
                    CustomDockMenuAction(title: "Open Reminders") { [weak self] in self?.openApp("com.apple.reminders") }]
        case .battery:
            return [CustomDockMenuAction(title: "Battery Settings…") { [weak self] in self?.openURL("x-apple.systempreferences:com.apple.Battery-Settings.extension") },
                    CustomDockMenuAction(title: "Activity Monitor (Energy)") { [weak self] in self?.openApp("com.apple.ActivityMonitor") }]
        }
    }

    // MARK: - Context menu and editing

    private func menu(for index: Int) -> [CustomDockMenuAction] {
        guard model.items.indices.contains(index) else { return [] }
        let item = model.items[index]
        var actions: [CustomDockMenuAction] = []
        switch item.content {
        case .app:
            actions.append(CustomDockMenuAction(title: item.isRunning ? "Show" : "Open") { [weak self] in self?.open(item) })
            if let app = item.source.runningApp {
                actions.append(CustomDockMenuAction(title: app.isHidden ? "Unhide" : "Hide") {
                    if app.isHidden { app.unhide() } else { app.hide() }
                })
                actions.append(CustomDockMenuAction(title: "Quit", destructive: true) { app.terminate() })
            }
            if let url = item.url {
                actions.append(CustomDockMenuAction(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
                if prefs.customDockUseOwnItems {
                    if item.entryID == nil {
                        actions.append(CustomDockMenuAction(title: "Keep in Dock") { [weak self] in self?.edit { $0.append(.app(url.path)) } })
                    }
                    for group in prefs.customDockEntries where group.kind == .group && !group.apps.contains(url.path) {
                        actions.append(CustomDockMenuAction(title: "Add to \(group.title)") { [weak self] in
                            self?.edit { entries in entries = entries.map { e in
                                guard e.id == group.id else { return e }
                                var copy = e
                                copy.apps.append(url.path)
                                return copy
                            } }
                        })
                    }
                }
            }
            if item.url != nil {
                actions.append(CustomDockMenuAction(title: "New Group with \(item.title)") { [weak self] in self?.newGroup(at: index) })
            }
        case .folder(let url):
            actions.append(CustomDockMenuAction(title: "Open") { NSWorkspace.shared.open(url) })
            actions.append(CustomDockMenuAction(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        case .group:
            actions.append(CustomDockMenuAction(title: "Rename…") { [weak self] in self?.renameGroup(at: index) })
            actions.append(CustomDockMenuAction(title: "Ungroup") { [weak self] in self?.ungroup(at: index) })
        case .widget(let kind):
            actions += widgetActions(kind)
        case .stack(let kinds):
            for kind in kinds { actions += widgetActions(kind) }
        case .spacer, .divider:
            break
        case .trash(let full):
            actions.append(CustomDockMenuAction(title: "Open") { TrashBin.open() })
            if full {
                actions.append(CustomDockMenuAction(title: "Empty Trash…", destructive: true) { [weak self] in
                    TrashBin.empty { self?.reloadIfEnabled() }
                })
            }
        }
        if let entryID = item.entryID {
            actions.append(CustomDockMenuAction(title: "Remove from Dock", destructive: true) { [weak self] in
                self?.edit { $0 = $0.filter { $0.id != entryID } }
            })
        }
        actions.append(CustomDockMenuAction(title: "Dock Settings…") { SettingsWindow.shared.show() })
        return actions
    }

    private func edit(_ change: (inout [DockEntry]) -> Void) {
        var entries = prefs.customDockEntries
        change(&entries)
        prefs.customDockEntries = entries
    }

    // MARK: - Arranging on the Dock (drag to move, drop onto an app to group)

    /// Your arrangement lined up with the Dock as shown, one slot per item: saved entries as they
    /// are, other apps (mirrored from Apple's Dock, or running and unpinned) as new app entries,
    /// nil for the running-apps divider.
    private func alignedEntries() -> [DockEntry?] {
        var saved: [UUID: DockEntry] = [:]
        for e in prefs.customDockEntries { saved[e.id] = e }
        return model.items.map { item in
            if let id = item.entryID, let e = saved[id] { return e }
            if item.content == .app, let url = item.url { return .app(url.path) }
            return nil
        }
    }

    /// Saves an edited alignment. Saved slots stay; new slots stay only if the edit touched them
    /// (`keep`), so running apps you didn't move stay unpinned. Mirroring Apple's Dock switches to
    /// your own arrangement, seeded with every app shown. Entries not on the Dock right now (an
    /// app that's not installed) are kept at the end.
    private func commit(_ aligned: [DockEntry?], keep: Set<UUID>) {
        let own = prefs.customDockUseOwnItems
        let savedIDs = Set(prefs.customDockEntries.map(\.id))
        let shownIDs = Set(model.items.compactMap(\.entryID))
        let hidden = own ? prefs.customDockEntries.filter { !shownIDs.contains($0.id) } : []
        let kept = aligned.compactMap { $0 }.filter { !own || savedIDs.contains($0.id) || keep.contains($0.id) }
        prefs.customDockEntries = kept + hidden
        if !own { prefs.customDockUseOwnItems = true }
    }

    private func canMove(_ index: Int) -> Bool {
        guard model.items.indices.contains(index) else { return false }
        let item = model.items[index]
        return item.entryID != nil || (item.content == .app && item.url != nil)
    }

    private func drop(_ from: Int, _ target: CustomDockDrop) {
        var slots = alignedEntries()
        guard slots.indices.contains(from), let moving = slots[from] else { return }
        var keep: Set<UUID> = [moving.id]
        switch target {
        case .insert(let at):
            slots.remove(at: from)
            let to = min(at > from ? at - 1 : at, slots.count)
            slots.insert(moving, at: to)
            // Dropped among the running apps: pin every app shown, in the order shown, so it stays
            // exactly where it was dropped (only saved items keep a place; pinning only the ones
            // before it made it jump in front of the divider).
            let dividerAt = slots.firstIndex { $0 == nil }
            if let dividerAt, to > dividerAt {
                for slot in slots { if let slot { keep.insert(slot.id) } }
            }
        case .group(let k):
            guard slots.indices.contains(k), let onto = slots[k], let path = moving.path else { return }
            var merged: DockEntry
            if onto.kind == .group {
                merged = onto
                if !merged.apps.contains(path) { merged.apps.append(path) }
            } else if onto.kind == .app, let ontoPath = onto.path {
                merged = .group(nextGroupName(), apps: [ontoPath, path])
            } else { return }
            slots[k] = merged
            slots.remove(at: from)
            keep.insert(merged.id)
        case .remove:
            slots.remove(at: from)
            keep = []
        }
        commit(slots, keep: keep)
    }

    private func nextGroupName() -> String {
        "Group \(prefs.customDockEntries.filter { $0.kind == .group }.count + 1)"
    }

    private func newGroup(at index: Int) {
        var slots = alignedEntries()
        guard slots.indices.contains(index), let app = slots[index], let path = app.path else { return }
        let group = DockEntry.group(nextGroupName(), apps: [path])
        slots[index] = group
        commit(slots, keep: [group.id])
    }

    private func ungroup(at index: Int) {
        var slots = alignedEntries()
        guard slots.indices.contains(index), let group = slots[index], group.kind == .group else { return }
        let apps = group.apps.map(DockEntry.app)
        slots.replaceSubrange(index...index, with: apps.map(Optional.some))
        commit(slots, keep: Set(apps.map(\.id)))
    }

    /// Opens the group's grid with the cursor in its name.
    private func renameGroup(at index: Int) {
        guard let panel = panels.first(where: { $0.isVisible }) ?? panels.first else { return }
        openGroup(at: index, on: panel, focusTitle: true)
    }

    private func openGroup(at index: Int, on panel: CustomDockPanel, focusTitle: Bool = false) {
        guard let item = model.items[safe: index], case .group(let apps) = item.content else { return }
        let anchor = globalRect(layout(for: panel).itemRect(index), in: panel)
        stack.toggle(title: item.title, entries: DockStackPanel.entries(apps: apps), folder: nil, group: item.entryID,
                     focusTitle: focusTitle, anchor: anchor, dock: geometry(on: panel))
    }

    private func renameGroup(id: UUID, to name: String) {
        edit { $0 = $0.map { e in
            guard e.id == id else { return e }
            var copy = e
            copy.name = name
            return copy
        } }
    }

    private func ungroup(id: UUID) {
        guard let index = model.items.firstIndex(where: { $0.entryID == id }) else { return }
        ungroup(at: index)
    }

    /// Takes one app out of a group and puts it on the Dock right after the group; a group left
    /// empty turns into that app.
    private func removeFromGroup(id: UUID, app url: URL) {
        var slots = alignedEntries()
        guard let k = slots.firstIndex(where: { $0?.id == id }), var group = slots[k] else { return }
        group.apps.removeAll { $0 == url.path }
        let app = DockEntry.app(url.path)
        if group.apps.isEmpty {
            slots[k] = app
        } else {
            slots[k] = group
            slots.insert(app, at: k + 1)
        }
        commit(slots, keep: [group.id, app.id])
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The user's Trash for the Dock's Trash item: full or empty, open, empty, and moving files in.
@MainActor
enum TrashBin {
    nonisolated static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true) }

    /// Anything in the Trash besides Finder's bookkeeping. Reading it can be refused without
    /// Full Disk Access; then it counts as empty.
    nonisolated static var isFull: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { $0 != ".DS_Store" && $0 != ".localized" }
    }

    static func icon(full: Bool) -> NSImage {
        NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Finder's own Trash window (`~/.Trash` is hidden, so opening the folder shows nothing).
    static func open() {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\"\n activate\n open trash\n end tell")?.executeAndReturnError(&error)
            guard let error else { return }
            NSLog("win-tab: open trash via Finder failed: \(error)")
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    /// Moves files to the Trash, as dropping them on Apple's Trash does.
    static func recycle(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error { NSLog("win-tab: couldn't move to Trash: \(error)") }
        }
    }

    /// Asks first, then has Finder empty it (Finder knows about locked items and other volumes).
    static func empty(done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "You can't undo this."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
            if let error { NSLog("win-tab: empty trash failed: \(error)") }
            DispatchQueue.main.async { done() }
        }
    }
}
