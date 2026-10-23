import AppKit
import SwiftUI

/// The grid that opens from a group or folder on win-tab's Dock, like a Dock stack.
/// Clicking an item opens it; clicking anywhere else closes the grid. A group's grid also
/// renames it (type in the title), ungroups it, and lets apps be dragged out of it.
@MainActor
final class DockStackPanel: NSPanel {
    struct Entry: Identifiable {
        let url: URL
        let name: String
        let icon: NSImage
        var id: URL { url }
    }

    final class Model: ObservableObject {
        @Published var title = ""
        @Published var entries: [Entry] = []
        @Published var folder: URL?
        /// Set for a group's grid.
        @Published var group: UUID?
        /// Bumped on every open; the title field then takes the cursor only if `wantsTitleFocus`.
        @Published var focusRequest = 0
        var wantsTitleFocus = false
    }

    /// What a group's grid changes, carried out by the Dock.
    struct GroupActions {
        var rename: (UUID, String) -> Void
        var ungroup: (UUID) -> Void
        /// Takes an app out of the group, placing it on the Dock right after it.
        var remove: (UUID, URL) -> Void
        /// Saves a new order of the group's apps.
        var reorder: (UUID, [URL]) -> Void
    }

    var groupActions: GroupActions?
    /// Fading out; a toggle in the meantime reopens instead of closing again.
    private var closing = false
    private var closeGeneration = 0
    /// The title as opened, to tell whether typing changed it.
    private var openedTitle = ""

    static let maxFolderItems = 48
    /// Layout shared by the panel's size and the view, like an iPhone folder: a title over a
    /// rounded card holding the icons.
    enum Metrics {
        static let cell = CGSize(width: 86, height: 94)
        static let rowSpacing: CGFloat = 6
        static let cardPadding: CGFloat = 16
        static let outerPadding: CGFloat = 14
        static let titleHeight: CGFloat = 30
        static let titleGap: CGFloat = 10
        /// Rows shown before the card scrolls.
        static let maxRows = 4
        static let minWidth: CGFloat = 250

        /// Groups use three columns like an iPhone folder; folders, with more files, use five.
        static func columns(count: Int, folder: Bool) -> Int { min(max(count, 1), folder ? 5 : 3) }
        static func rows(count: Int, folder: Bool) -> Int {
            max(1, Int(ceil(Double(max(count, 1)) / Double(columns(count: count, folder: folder)))))
        }
        static func cardHeight(rows: Int) -> CGFloat {
            let shown = min(rows, maxRows)
            return CGFloat(shown) * cell.height + CGFloat(shown - 1) * rowSpacing + cardPadding * 2
        }
        /// Centre of slot `i` in the grid's own coordinates.
        static func center(of i: Int, columns cols: Int) -> CGPoint {
            CGPoint(x: (CGFloat(i % cols) + 0.5) * cell.width,
                    y: CGFloat(i / cols) * (cell.height + rowSpacing) + cell.height / 2)
        }

        /// The slot under `p` (grid coordinates), clamped to the `count` slots.
        static func index(at p: CGPoint, columns cols: Int, count: Int) -> Int {
            let col = min(max(Int(floor(p.x / cell.width)), 0), cols - 1)
            let row = max(Int(floor(p.y / (cell.height + rowSpacing))), 0)
            return min(row * cols + col, count - 1)
        }

        #if DEBUG
        static func selfCheck() -> [String] {
            var failures: [String] = []
            for i in 0..<7 where index(at: center(of: i, columns: 3), columns: 3, count: 7) != i { failures.append("stack slot \(i) round-trip") }
            if index(at: CGPoint(x: -40, y: -40), columns: 3, count: 7) != 0 { failures.append("stack slot clamps low") }
            if index(at: CGPoint(x: 9999, y: 9999), columns: 3, count: 7) != 6 { failures.append("stack slot clamps high") }
            return failures
        }
        #endif

        static func size(count: Int, folder: Bool) -> CGSize {
            let cols = columns(count: count, folder: folder)
            let width = max(CGFloat(cols) * cell.width + cardPadding * 2, minWidth) + outerPadding * 2
            let height = titleHeight + titleGap + cardHeight(rows: rows(count: count, folder: folder)) + outerPadding * 2
            return CGSize(width: width, height: height)
        }
    }
    private static let gap: CGFloat = 8

    private let model = Model()
    private var monitors: [Any] = []

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: DockStackView(
            model: model,
            open: { [weak self] url in
                self?.close()
                NSWorkspace.shared.open(url)
            },
            rename: { [weak self] in self?.commitTitle() },
            ungroup: { [weak self] in
                guard let self, let id = self.model.group else { return }
                self.model.group = nil
                self.close()
                self.groupActions?.ungroup(id)
            },
            remove: { [weak self] url in self?.remove(url) },
            reorder: { [weak self] urls in
                guard let self, let id = self.model.group else { return }
                self.groupActions?.reorder(id, urls)
            },
            isOutside: { [weak self] in
                guard let self else { return false }
                return !self.frame.insetBy(dx: 6, dy: 6).contains(NSEvent.mouseLocation)
            }))
        host.wantsLayer = true
        contentView = host
    }

    #if DEBUG
    /// A group grid with sample apps, for the illustrations shot.
    static func debugPreview() -> some View {
        let model = Model()
        model.title = "app"
        model.group = UUID()
        model.entries = entries(apps: ["/System/Applications/Music.app", "/System/Applications/Notes.app", "/System/Applications/Calendar.app"].map { URL(fileURLWithPath: $0) })
        return DockStackView(model: model, open: { _ in }, rename: {}, ungroup: {}, remove: { _ in }, reorder: { _ in }, isOutside: { false })
            .frame(width: Metrics.size(count: 3, folder: false).width, height: Metrics.size(count: 3, folder: false).height)
    }
    #endif

    /// A group's grid takes the keyboard for its title field (without activating win-tab).
    override var canBecomeKey: Bool { model.group != nil }

    private func commitTitle() {
        let name = model.title.trimmingCharacters(in: .whitespaces)
        guard let id = model.group, !name.isEmpty, name != openedTitle else { return }
        openedTitle = name
        groupActions?.rename(id, name)
    }

    private func remove(_ url: URL) {
        guard let id = model.group else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.entries.removeAll { $0.url == url } }
        groupActions?.remove(id, url)
        if model.entries.isEmpty { model.group = nil; close() }
    }

    /// Group members, as app entries.
    static func entries(apps: [URL]) -> [Entry] {
        apps.map { Entry(url: $0, name: DockEntry.displayName($0.path), icon: NSWorkspace.shared.icon(forFile: $0.path)) }
    }

    /// A folder's visible contents, folders first, then by name.
    static func entries(folder: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .localizedNameKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let sorted = urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let db = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if da != db { return da }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        return sorted.prefix(maxFolderItems).map {
            Entry(url: $0, name: FileManager.default.displayName(atPath: $0.path), icon: NSWorkspace.shared.icon(forFile: $0.path))
        }
    }

    func toggle(title: String, entries: [Entry], folder: URL?, group: UUID? = nil, focusTitle: Bool = false, anchor: CGRect, dock: DockGeometry) {
        if isVisible && !closing && openedTitle == title && !focusTitle { close(); return }
        commitTitle()
        model.title = title
        openedTitle = title
        model.entries = entries
        model.folder = folder
        model.group = group
        let size = Metrics.size(count: entries.count, folder: folder != nil)
        setFrame(CGRect(origin: dock.cardOrigin(size: size, anchor: anchor, clearance: dock.reach + Self.gap), size: size), display: true)
        let reopening = isVisible && !closing
        closing = false
        closeGeneration += 1
        alphaValue = 1
        orderFrontRegardless()
        if !reopening { popIn() }
        if focusTitle { makeKey() }
        model.wantsTitleFocus = focusTitle
        model.focusRequest += 1
        // AppKit hands the title field the cursor on its own; take it back unless renaming.
        if !focusTitle {
            DispatchQueue.main.async { [weak self] in _ = self?.makeFirstResponder(nil) }
        }
        watchOutsideClicks()
    }

    override func close() {
        commitTitle()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        guard isVisible, !closing else { return }
        closing = true
        closeGeneration += 1
        let mine = closeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closeGeneration == mine else { return }
                self.closing = false
                self.orderOut(nil)
                self.alphaValue = 1
            }
        })
    }

    /// Grows in from 92% with a light spring and fades in, on the render server.
    private func popIn() {
        guard let layer = contentView?.layer else { return }
        let s: CGFloat = 0.92
        let size = layer.bounds.size
        let start = CATransform3DScale(CATransform3DMakeTranslation(size.width * (1 - s) / 2, size.height * (1 - s) / 2, 0), s, s, 1)
        let grow = CASpringAnimation(keyPath: "sublayerTransform")
        grow.fromValue = NSValue(caTransform3D: start)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.stiffness = 380
        grow.damping = 26
        grow.duration = grow.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "popIn.grow")
        layer.add(fade, forKey: "popIn.fade")
    }

    private func watchOutsideClicks() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let outside = { [weak self] in
            guard let self, !self.frame.contains(NSEvent.mouseLocation) else { return }
            self.close()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in MainActor.assumeIsolated { outside() } }) {
            monitors.append(m)
        }
        // Clicks on win-tab's own Dock are local events; the Dock's click handler toggles the grid itself.
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            if event.window !== self && !(event.window is CustomDockPanel) { outside() }
            return event
        }) {
            monitors.append(m)
        }
    }
}

private struct DockStackView: View {
    @ObservedObject var model: DockStackPanel.Model
    @ObservedObject private var prefs = SwitchPreferences.shared
    @ObservedObject private var style = StylePreferences.shared
    let open: (URL) -> Void
    let rename: () -> Void
    let ungroup: () -> Void
    let remove: (URL) -> Void
    let reorder: ([URL]) -> Void
    /// Whether the pointer is outside the grid now (a drag ending there takes the app out).
    let isOutside: () -> Bool
    @State private var hovered: URL?
    @State private var dragging: URL?
    @State private var dragOffset: CGSize = .zero
    @State private var draggedOut = false
    /// Where in its icon the dragged app was grabbed, and the order when the drag began.
    @State private var grab: CGSize = .zero
    @State private var orderAtStart: [URL] = []
    @State private var titleHovered = false
    @State private var ungroupHovered = false
    @FocusState private var titleFocused: Bool

    private static let spring = Animation.spring(response: 0.28, dampingFraction: 0.78)
    private static let gridSpace = "stackGrid"

    private typealias M = DockStackPanel.Metrics
    private var isFolder: Bool { model.folder != nil }

    var body: some View {
        VStack(spacing: M.titleGap) {
            header
            card
        }
        .padding(M.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if prefs.backgroundBlur != .glass { Rectangle().fill(prefs.backgroundBlur.material) }
        }
        .flatTint(style.dockTint, glass: prefs.backgroundBlur == .glass)
        .liquidGlass(prefs.backgroundBlur == .glass, cornerRadius: 26, tint: style.dockTint)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .onChange(of: model.focusRequest) { _, _ in titleFocused = model.wantsTitleFocus }
        .focusEffectDisabled()
    }

    // MARK: Header

    /// Centred title like an iPhone folder, with the action as a round button at the side.
    private var header: some View {
        ZStack {
            if model.group != nil {
                titleField
            } else {
                Text(model.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            }
            HStack {
                Spacer()
                if model.group != nil {
                    RoundIconButton(symbol: "square.stack.3d.up.slash", help: "Ungroup", accent: prefs.accent.color, action: ungroup)
                } else if let folder = model.folder {
                    RoundIconButton(symbol: "folder", help: "Open in Finder", accent: prefs.accent.color) { open(folder) }
                }
            }
        }
        .frame(height: M.titleHeight)
    }

    /// The icons on a rounded card, scrolling only past `maxRows` rows.
    private var card: some View {
        let cols = M.columns(count: model.entries.count, folder: isFolder)
        let rows = M.rows(count: model.entries.count, folder: isFolder)
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(M.cell.width), spacing: 0), count: cols), spacing: M.rowSpacing) {
            ForEach(model.entries) { cell($0) }
        }
        .coordinateSpace(name: Self.gridSpace)
        return Group {
            if model.entries.isEmpty {
                Text(isFolder ? "This folder is empty." : "No apps in this group yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows > M.maxRows {
                ScrollView(.vertical, showsIndicators: false) { grid.padding(.vertical, M.cardPadding) }
            } else {
                grid.padding(.vertical, M.cardPadding)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: M.cardHeight(rows: rows))
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    /// Looks like a title; shows it's editable on hover and while typing.
    private var titleField: some View {
        let active = titleFocused || titleHovered
        return HStack(spacing: 6) {
            TextField("Group name", text: $model.title)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .focused($titleFocused)
                .onSubmit { rename(); titleFocused = false }
                .fixedSize()
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(active && !titleFocused ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(titleFocused ? 0.1 : titleHovered ? 0.06 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(prefs.accent.color.opacity(titleFocused ? 0.7 : 0), lineWidth: 1))
        .onHover { titleHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
    }

    // MARK: Cells

    private func cell(_ entry: DockStackPanel.Entry) -> some View {
        let isHovered = hovered == entry.url && dragging == nil
        let isDragged = dragging == entry.url
        return VStack(spacing: 6) {
            Image(nsImage: entry.icon).resizable().interpolation(.high)
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(isHovered || isDragged ? 0.35 : 0.15), radius: isHovered || isDragged ? 8 : 3, y: isHovered ? 4 : 1)
                .scaleEffect(isDragged ? 1.12 : isHovered ? 1.08 : 1)
                .offset(y: isHovered ? -2 : 0)
            Text(entry.name).font(.system(size: 11, weight: isHovered ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 78)
                .opacity(isDragged ? 0 : 1)
        }
        .padding(.top, 6)
        // Top-aligned so two-line names don't push their icon out of the row.
        .frame(width: M.cell.width, height: M.cell.height, alignment: .top)
        .overlay(alignment: .topTrailing) {
            // Letting go here takes the app out of the group.
            if isDragged && draggedOut {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .offset(x: -8, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .offset(isDragged ? dragOffset : .zero)
        .zIndex(isDragged ? 1 : 0)
        // The dragged app follows the pointer exactly; only the others glide to their new slots.
        .transaction { if isDragged { $0.animation = nil } }
        .animation(Self.spring, value: isHovered)
        .animation(.easeOut(duration: 0.15), value: draggedOut)
        .onHover { hovered = $0 ? entry.url : (hovered == entry.url ? nil : hovered) }
        .onTapGesture { open(entry.url) }
        .gesture(model.group == nil ? nil : DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.gridSpace))
            .onChanged { dragChanged(entry.url, $0) }
            .onEnded { _ in dragEnded(entry.url) })
        .contextMenu {
            if model.group != nil {
                Button("Remove from Group") { remove(entry.url) }
            }
        }
    }

    // MARK: Dragging (reorder inside, or out of the group)

    private var columns: Int { M.columns(count: model.entries.count, folder: isFolder) }

    private func dragChanged(_ url: URL, _ value: DragGesture.Value) {
        if dragging == nil {
            let start = model.entries.firstIndex { $0.url == url } ?? 0
            let c = M.center(of: start, columns: columns)
            grab = CGSize(width: value.startLocation.x - c.x, height: value.startLocation.y - c.y)
            orderAtStart = model.entries.map(\.url)
            dragging = url
        }
        draggedOut = isOutside()
        guard var from = model.entries.firstIndex(where: { $0.url == url }) else { return }
        if !draggedOut {
            let to = M.index(at: CGPoint(x: value.location.x - grab.width, y: value.location.y - grab.height),
                             columns: columns, count: model.entries.count)
            if to != from {
                withAnimation(Self.spring) {
                    let moving = model.entries.remove(at: from)
                    model.entries.insert(moving, at: to)
                }
                from = to
            }
        }
        let c = M.center(of: from, columns: columns)
        dragOffset = CGSize(width: value.location.x - c.x - grab.width, height: value.location.y - c.y - grab.height)
    }

    private func dragEnded(_ url: URL) {
        let out = isOutside()
        withAnimation(Self.spring) {
            dragging = nil
            dragOffset = .zero
            draggedOut = false
        }
        if out {
            remove(url)
        } else if model.entries.map(\.url) != orderAtStart {
            reorder(model.entries.map(\.url))
        }
    }
}

/// Round accent button with an icon, brightening on hover.
private struct RoundIconButton: View {
    let symbol: String
    let help: String
    let accent: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(accent.opacity(hovered ? 0.35 : 0.18)))
                .foregroundStyle(hovered ? Color.primary : accent)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
