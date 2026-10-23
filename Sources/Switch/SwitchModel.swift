import AppKit
import SwiftUI

@MainActor
final class SwitchModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var selected: Int = 0
    @Published var mode: HotkeyManager.Mode = .allWindows
    @Published var visible: Bool = false
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    /// Bundle ID → Dock badge text (unread counts), read when the picker arms.
    @Published var badges: [String: String] = [:]
    @Published var filterText: String = ""
    @Published var panelSize = CGSize(width: 880, height: 560)
    /// Effective sticky for this invocation: global pref or a dedicated sticky binding (#131).
    @Published var stickySession = false
    private var currentSpaceOnly = false
    /// Picker display in CGWindow coordinates, captured at arm. Nil when the display filter is off.
    private var armDisplayFrame: CGRect?
    private var armFrontWindowID: CGWindowID?
    private var armReverse = false

    /// Set by AppDelegate so the view can request a commit + window dismiss from a mouse click.
    var commitAndDismiss: (() -> Void)?
    /// Set by AppDelegate so the model can request a dismiss when no windows remain after a close.
    var cancelAndDismiss: (() -> Void)?

    private var refreshTimer: Timer?
    private var prewarmTimer: Timer?
    private var armGeneration = 0
    private var armFrontmostPID: pid_t?
    private var armSelfHadKeyWindow = false
    private var quitPIDs: Set<pid_t> = []
    /// Windows closed from the picker. Tray apps (Zalo, Telegram) only order them out, so they
    /// stay in the window list, and the next open starts from a snapshot taken before the close.
    /// They stay off the picker until they're on screen again (the app was reopened).
    private static var closedWindowIDs: [CGWindowID: Date] = [:]
    private var thumbnailTasks: [Task<Void, Never>] = []
    var pointerWindowID: CGWindowID?

    var filteredWindows: [WindowInfo] {
        let q = Self.searchKey(filterText)
        if q.isEmpty { return windows }
        let scored: [(WindowInfo, Int)] = windows.compactMap { w in
            let a = Self.fuzzyScore(pattern: q, target: Self.searchKey(w.appName))
            let t = Self.fuzzyScore(pattern: q, target: Self.searchKey(w.title))
            guard let s = [a, t].compactMap({ $0 }).max() else { return nil }
            return (w, s)
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Lowercased and accent-folded ("Tiếng Việt" → "tieng viet", "đ" → "d"). Type-to-filter reads raw
    /// keys off the event tap, so an IME never composes (#89); folding lets unaccented input match.
    /// ponytail: kana/CJK still can't be typed, that needs a real text input in the picker.
    static func searchKey(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
    }

    private static func fuzzyScore(pattern: String, target: String) -> Int? {
        let pat = Array(pattern)
        let tgt = Array(target)
        var score = 0
        var patIdx = 0
        var lastMatch = -1
        for (i, c) in tgt.enumerated() {
            guard patIdx < pat.count else { break }
            if c == pat[patIdx] {
                score += 1
                if lastMatch == i - 1 { score += 5 }
                if i == 0 || !tgt[i - 1].isLetter { score += 3 }
                lastMatch = i
                patIdx += 1
            }
        }
        return patIdx == pat.count ? score : nil
    }

    /// Off the main thread: reading the Dock over AX must not delay the picker opening. The
    /// previous badges stay up until the fresh read lands.
    private func refreshBadges() {
        guard SwitchPreferences.shared.showDockBadges else { badges = [:]; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = DockAX.badges()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.badges != fresh else { return }
                self.badges = fresh
            }
        }
    }

    func arm(_ style: HotkeyManager.ArmStyle) {
        armGeneration &+= 1
        let gen = armGeneration
        self.mode = style.mode
        stickySession = style.sticky
        currentSpaceOnly = style.currentSpaceOnly
        armDisplayFrame = (style.currentDisplayOnly || SwitchPreferences.shared.currentDisplayOnly)
            ? SwitcherWindow.pickerScreen().map(Self.cgFrame) : nil
        armReverse = style.reverse
        quitPIDs.removeAll()
        filterText = ""
        pointerWindowID = nil
        armFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        armSelfHadKeyWindow = NSApp.keyWindow != nil
        refreshBadges()
        if let snap = WindowStore.shared.current {
            apply(snapshot: snap, initial: true)
        } else {
            windows = []
            selected = 0
        }
        visible = true
        WindowStore.shared.refresh { [weak self] snap in
            guard let self, self.armGeneration == gen, self.visible else { return }
            self.apply(snapshot: snap, initial: self.windows.isEmpty)
        }
        startRefreshTimer()
    }

    private func apply(snapshot: WindowStore.Snapshot, initial: Bool) {
        let previousSelectedID: CGWindowID? = {
            guard !initial else { return nil }
            let list = filteredWindows
            return list.indices.contains(selected) ? list[selected].id : nil
        }()

        let final: [WindowInfo]
        if mode == .spaces {
            let active = Int(CGSGetActiveSpace(CGSMainConnectionID()))
            final = snapshot.windows.spaceRepresentatives.map { rep in
                var out = rep
                out.isCrossSpace = out.spaceID != active
                out.spaceLabel = out.spaceID == active ? "Current" : nil
                return out
            }
        } else {
            final = buildWindowList(from: snapshot.windows)
        }
        let changed = final != windows
        if changed { windows = final }

        if initial {
            armFrontWindowID = WindowMRU.mostRecent(in: snapshot.windows.allWindows)?.id
            if mode == .spaces {
                let reps = filteredWindows
                if let current = reps.firstIndex(where: { !$0.isCrossSpace }), reps.count > 1 {
                    selected = (current + 1) % reps.count
                } else {
                    selected = 0
                }
            } else {
                // Own windows aren't listed, so with Switch frontmost index 0 is already the previous window.
                // Only treat Switch as frontmost when it genuinely owns a visible key window (Settings/About/
                // onboarding); the picker panel can't become key, so keyWindow != nil rules out the stale
                // "still frontmost after closing a window" state behind #90.
                let n = filteredWindows.count
                selected = (stickySession || selfFront) ? 0
                    : armReverse ? max(n - 1, 0)
                    : (frontListed && n > 1 ? 1 : 0)
            }
        } else if changed {
            let list = filteredWindows
            if let previousSelectedID, let idx = list.firstIndex(where: { $0.id == previousSelectedID }) {
                selected = idx
            } else if selected >= list.count {
                selected = max(list.count - 1, 0)
            }
        }

        thumbnailTasks.forEach { $0.cancel() }
        thumbnailTasks = []
        let thumbTargets = final.filter { !$0.isWindowless }
        let gen = armGeneration
        if initial {
            let task = Task {
                await fetchThumbnails(for: thumbTargets, force: false)
            }
            thumbnailTasks.append(task)
        } else {
            let liveIDs = Set(thumbTargets.map { $0.id })
            let task = Task {
                if SwitchPreferences.shared.showThumbnails {
                    // Don't full-purge; pre-warmed thumbs are valid as long as the window still exists.
                    await WindowSnapshotter.shared.purge(keeping: liveIDs)
                }
                await fetchThumbnails(for: thumbTargets, force: false)
                guard armGeneration == gen, visible else { return }
                await fetchThumbnails(for: thumbTargets, force: true, batch: true)
            }
            thumbnailTasks.append(task)
        }
    }

    // FocusTracker keeps WindowMRU current across all focus events (Switch-driven
    // and external clicks). MRU-sort active-Space too so that when an Arc window
    // is raised, all OTHER Arc windows don't cluster ahead of the previously-focused
    // window from a different app. CGWindowList z-order groups windows by app
    // when any one is raised, which is the wrong signal for a window switcher.
    struct RegularApp: Sendable { let pid: pid_t; let name: String; let bundleID: String? }
    /// Regular (Dock) apps, read off the main thread: every `NSRunningApplication` property asks
    /// LaunchServices (~1 ms per app), which stalled each ⌘-Tab open by ~30 ms.
    // ponytail: one open behind — an app launched since the last refresh shows up from the next open.
    private static var regularApps: [RegularApp] = []
    static func refreshRegularApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let own = Bundle.main.bundleIdentifier
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != own }
                .map { RegularApp(pid: $0.processIdentifier, name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier) }
            Task { @MainActor in regularApps = apps }
        }
    }

    /// Closed-from-the-picker windows still hidden: drops those that are gone or back on screen.
    private static func stillClosed(in full: WindowEnumerator.FullSnapshot) -> Set<CGWindowID> {
        guard !closedWindowIDs.isEmpty else { return [] }
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let shown = Set(onScreen), listed = full.allIDs
        // The close animation keeps a window on screen for a moment; only later does "on screen" mean reopened.
        closedWindowIDs = closedWindowIDs.filter { id, at in
            listed.contains(id) && !(shown.contains(id) && Date().timeIntervalSince(at) > 1.5)
        }
        return Set(closedWindowIDs.keys)
    }

    private func buildWindowList(from full: WindowEnumerator.FullSnapshot) -> [WindowInfo] {
        var active = full.activeSpace
        var cross = full.crossSpace
        let closed = Self.stillClosed(in: full)
        active.removeAll { closed.contains($0.id) }
        cross.removeAll { closed.contains($0.id) }
        // An app whose every window was closed, or that is hidden (⌘H, the picker's moon), shows
        // as a chip in the NO WINDOWS strip rather than as its windows.
        let open = full.allWindows.filter { !closed.contains($0.id) }
        Self.hiddenByPicker = Self.hiddenByPicker.filter { Date().timeIntervalSince($0.value) < 5 }
        let hiddenPIDs: Set<pid_t> = SwitchPreferences.shared.includeWindowlessApps && mode == .allWindows
            ? Set(Dictionary(grouping: open, by: \.pid).filter { $0.value.allSatisfy(\.isHidden) }.keys).union(Self.hiddenByPicker.keys) : []
        active.removeAll { hiddenPIDs.contains($0.pid) }
        cross.removeAll { hiddenPIDs.contains($0.pid) }
        let switchablePIDs = Set(open.map(\.pid)).subtracting(hiddenPIDs)
        active.removeAll { quitPIDs.contains($0.pid) }
        cross.removeAll { quitPIDs.contains($0.pid) }
        if SwitchPreferences.shared.hideMinimizedWindows {
            active.removeAll { $0.isMinimized || $0.isHidden }
            cross.removeAll { $0.isMinimized || $0.isHidden }
        }
        let exclusions = SwitchPreferences.shared.titleExclusions.map { $0.lowercased() }
        if !exclusions.isEmpty {
            let hit: (WindowInfo) -> Bool = { w in
                let t = w.title.lowercased()
                return exclusions.contains { t.contains($0) }
            }
            active.removeAll(where: hit)
            cross.removeAll(where: hit)
        }
        if mode == .currentApp, let f = armFrontmostPID {
            active = active.filter { $0.pid == f }
            cross = cross.filter { $0.pid == f }
        }
        if !SwitchPreferences.shared.showCrossSpace || currentSpaceOnly {
            active = WindowEnumerator.onActiveSpace(active)
            cross = WindowEnumerator.onActiveSpace(cross.filter { !$0.isCrossSpace })
        }
        if let display = armDisplayFrame {
            active.removeAll { !$0.bounds.intersects(display) }
            cross.removeAll { !$0.bounds.intersects(display) }
        }
        let activeFront = WindowMRU.mostRecent(in: active) ?? active.first
        let ws: [WindowInfo]
        if SwitchPreferences.shared.staticOrder {
            let order = SwitchPreferences.shared.appOrder
            let rank: (String) -> Int = { order.firstIndex(of: $0) ?? Int.max }
            let stable: (WindowInfo, WindowInfo) -> Bool = {
                let ra = rank($0.appName), rb = rank($1.appName)
                if ra != rb { return ra < rb }
                if $0.appName.lowercased() != $1.appName.lowercased() {
                    return $0.appName.lowercased() < $1.appName.lowercased()
                }
                return $0.id < $1.id
            }
            ws = active.sorted(by: stable) + cross.sorted(by: stable)
        } else if SwitchPreferences.shared.mruMixSpaces {
            // Right after a cross-Space switch the cached snapshot still lists the
            // focused window as cross-Space; pin the frontmost app's MRU window from
            // either list so rows don't reshuffle under the selection when the fresh
            // sweep lands (#stale-arm reorder).
            let all = active + cross
            let front = armFrontmostPID.flatMap { p in WindowMRU.mostRecent(in: all.filter { $0.pid == p }) } ?? activeFront
            ws = WindowMRU.sorted(all, frontmost: front)
        } else {
            ws = WindowMRU.sorted(active, frontmost: activeFront) + WindowMRU.sorted(cross, frontmost: nil)
        }
        var final = ws
        if SwitchPreferences.shared.includeWindowlessApps && mode == .allWindows {
            let blacklist = SwitchPreferences.shared.blacklist
            Self.refreshRegularApps()
            let extras = Self.regularApps
                .filter {
                    !switchablePIDs.contains($0.pid)
                        && !quitPIDs.contains($0.pid)
                        && $0.bundleID.map(blacklist.contains) != true
                }
                .sorted { $0.name < $1.name }
                .map { app in
                    WindowInfo(
                        id: CGWindowID(0xF0000000) | CGWindowID(UInt32(bitPattern: Int32(app.pid))),
                        pid: app.pid,
                        appName: app.name,
                        bounds: .zero,
                        title: "",
                        isWindowless: true,
                        bundleID: app.bundleID
                    )
                }
            final += extras
        }
        let pinned = SwitchPreferences.shared.pinnedBundleIDs
        if !pinned.isEmpty {
            final.sort { (a, b) in
                let aP = a.bundleID.map { pinned.contains($0) } ?? false
                let bP = b.bundleID.map { pinned.contains($0) } ?? false
                return aP && !bP
            }
        }
        if SwitchPreferences.compactsWindowless(mode: mode) {
            // Windowless apps render as one strip after the tiles; keep the order the same.
            final = final.filter { !$0.isWindowless } + final.filter(\.isWindowless)
        }
        return final
    }

    func closeSelected() {
        let list = filteredWindows
        guard list.indices.contains(selected) else { return }
        close(list[selected])
    }

    func close(_ target: WindowInfo) {
        guard mode != .spaces else { return }
        if WindowCloser.close(target) { Self.closedWindowIDs[target.id] = Date() }
        removeFromPicker { $0.id == target.id }
    }

    /// Hides the app so macOS can throttle it (App Nap) while it keeps running; it moves to the
    /// NO WINDOWS strip, and picking it there shows the app again.
    func sendToBackground(_ target: WindowInfo) {
        guard mode != .spaces, target.pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: target.pid) else { return }
        // hide() only asks; macOS hides the app a moment later and the call often returns false
        // anyway. Move it to the strip now, and keep it there until `isHidden` catches up.
        app.hide()
        Self.hiddenByPicker[target.pid] = Date()
        moveToWindowless(target)
    }

    /// Apps hidden from the picker in the last few seconds: a window sweep taken before macOS
    /// finished hiding them still lists their windows as shown.
    private static var hiddenByPicker: [pid_t: Date] = [:]

    /// Shows the app as one chip in the NO WINDOWS strip instead of its windows.
    private func moveToWindowless(_ target: WindowInfo) {
        let pid = target.pid
        windows.removeAll { $0.pid == pid }
        if SwitchPreferences.shared.includeWindowlessApps && mode == .allWindows {
            windows.append(WindowInfo(id: CGWindowID(0xF0000000) | CGWindowID(UInt32(bitPattern: Int32(pid))), pid: pid,
                                      appName: target.appName, bounds: .zero, title: "", isWindowless: true, bundleID: target.bundleID))
        }
        removeFromPicker { _ in false }
    }

    /// Closes every window of the app but leaves it running: it moves to the NO WINDOWS strip.
    func closeAllWindows(of target: WindowInfo) {
        guard mode != .spaces, !target.isWindowless else { return }
        for id in WindowCloser.closeAll(pid: target.pid) { Self.closedWindowIDs[id] = Date() }
        moveToWindowless(target)
    }

    func closeWindow(withWindowID id: CGWindowID) {
        guard mode != .spaces else { return }
        guard let target = windows.first(where: { $0.id == id }) else { return }
        // Only the clicked window, like middle-clicking a browser tab. If no AX element
        // resolves (e.g. cross-Space Chromium window), do nothing rather than quit the app.
        guard WindowCloser.closeExact(target) else { return }
        Self.closedWindowIDs[target.id] = Date()
        removeFromPicker { $0.id == target.id }
    }

    private func removeFromPicker(_ shouldRemove: (WindowInfo) -> Bool) {
        windows.removeAll(where: shouldRemove)
        let liveIDs = Set(windows.map { $0.id })
        thumbnails = thumbnails.filter { liveIDs.contains($0.key) }
        let remaining = filteredWindows
        if remaining.isEmpty {
            cancelAndDismiss?()
            return
        }
        if selected >= remaining.count {
            selected = remaining.count - 1
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard SwitchPreferences.shared.showThumbnails else { return }
                let ws = self.windows.filter { !$0.isWindowless }
                guard !ws.isEmpty, self.visible else { return }
                await self.fetchThumbnails(for: ws, force: self.mode != .spaces, batch: true)
            }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func startPrewarm() {
        prewarmTimer?.invalidate()
        // Every arm refreshes on its own, so this only keeps the first frame warm.
        prewarmTimer = Timer.scheduledTimer(withTimeInterval: Self.prewarmInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.visible { return } // arm-driven refresh handles the visible case
                // Picker switched off: nobody will open it, so don't keep its cache warm.
                if !HotkeyManager.pickerEnabled { return }
                // Nobody switching windows (locked, or away a while): the cache is warm enough.
                if Self.screenIsLocked || SystemActivity.idleSeconds > Self.prewarmIdleCutoff { return }
                self.prewarmCache()
            }
        }
        prewarmTimer?.tolerance = 1
    }

    private static let prewarmInterval: TimeInterval = 10
    private static let prewarmIdleCutoff: TimeInterval = 120

    private static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func prewarmCache() {
        WindowStore.shared.refresh { snap in
            let ws = snap.windows.allWindows
            let liveIDs = Set(ws.map { $0.id })
            WindowMRU.purge(keeping: snap.windows.allIDs)
            Task.detached(priority: .utility) {
                AXWindowCache.purgeDead()
            }
            guard SwitchPreferences.shared.showThumbnails else { return }
            Task {
                await WindowSnapshotter.shared.purge(keeping: liveIDs)
                await withTaskGroup(of: Void.self) { group in
                    for w in ws {
                        group.addTask {
                            _ = await WindowSnapshotter.shared.snapshot(for: w.id, force: false)
                        }
                    }
                }
            }
        }
    }

    func advance(reverse: Bool) {
        let list = filteredWindows
        guard !list.isEmpty else { return }
        let n = list.count
        selected = reverse ? (selected - 1 + n) % n : (selected + 1) % n
    }

    func navigate(direction: HotkeyManager.Direction) {
        let list = filteredWindows
        guard !list.isEmpty else { return }
        let n = list.count
        let cols = (SwitchPreferences.shared.verticalList || mode == .spaces) ? 1 : SwitchPreferences.shared.gridColumns
        let delta: Int
        switch direction {
        case .left:  delta = -1
        case .right: delta = 1
        case .up:    delta = -cols
        case .down:  delta = cols
        }
        selected = ((selected + delta) % n + n) % n
    }

    func pickIndex(_ index: Int) {
        let list = filteredWindows
        guard list.indices.contains(index) else { return }
        selected = index
        commitAndDismiss?()
    }

    func selectIndex(_ index: Int) {
        let list = filteredWindows
        guard list.indices.contains(index) else { return }
        selected = index
    }

    func closeSelectedApp() {
        guard mode != .spaces else { return }
        let list = filteredWindows
        guard list.indices.contains(selected) else { return }
        let target = list[selected]
        AppCloser.close(target)
        quitPIDs.insert(target.pid)
        removeFromPicker { $0.pid == target.pid }
    }


    func hideSelected() {
        guard mode != .spaces else { return }
        let list = filteredWindows
        guard list.indices.contains(selected) else { return }
        let target = list[selected]
        if let app = NSRunningApplication(processIdentifier: target.pid) {
            app.hide()
        }
        cancelAndDismiss?()
    }

    func appendFilter(_ char: Character) {
        filterText.append(char)
        selected = 0
    }

    func backspaceFilter() {
        guard !filterText.isEmpty else { return }
        filterText.removeLast()
        selected = 0
    }

    private var selfFront: Bool {
        armFrontmostPID == ProcessInfo.processInfo.processIdentifier && armSelfHadKeyWindow
    }

    // False when a filter (display, title, app, hidden) dropped the focused window: index 0 is then already the previous one.
    private var frontListed: Bool {
        guard let id = armFrontWindowID else { return true }
        return filteredWindows.contains { $0.id == id }
    }

    // kCGWindowBounds has its origin at the top-left of the primary display; NSScreen at the bottom-left.
    private static func cgFrame(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? f.maxY
        return CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
    }

    func commit(stickyQuickTap: Bool = false) {
        let list = filteredWindows
        // Sticky preselects the current window, so a quick tap flips to the previous one instead (#96).
        if stickyQuickTap && mode != .spaces && selected == 0 && !selfFront && frontListed && list.count > 1 {
            selected = 1
        }
        if list.indices.contains(selected) {
            WindowFocuser.focus(list[selected])
            // Warm the cache once the Space transition settles so an immediate
            // re-invoke doesn't arm from a pre-switch snapshot (3s prewarm gap).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                WindowStore.shared.refresh()
            }
        }
        teardown()
    }

    func cancel() {
        teardown()
    }

    private func teardown() {
        visible = false
        windows = []
        thumbnails = [:]
        filterText = ""
        stopRefreshTimer()
        thumbnailTasks.forEach { $0.cancel() }
        thumbnailTasks = []
    }

    private func fetchThumbnails(for windows: [WindowInfo], force: Bool, batch: Bool = false) async {
        guard SwitchPreferences.shared.showThumbnails else {
            thumbnails = [:]
            return
        }
        var collected: [CGWindowID: NSImage] = [:]
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for w in windows {
                group.addTask {
                    let img = await WindowSnapshotter.shared.snapshot(for: w.id, force: force)
                    return (w.id, img)
                }
            }
            for await (id, img) in group {
                guard !Task.isCancelled else { return }
                if let img {
                    if batch { collected[id] = img }
                    else if visible { thumbnails[id] = img }
                }
            }
        }
        if batch, !collected.isEmpty, visible, !Task.isCancelled {
            thumbnails.merge(collected) { _, new in new }
        }
    }
}
