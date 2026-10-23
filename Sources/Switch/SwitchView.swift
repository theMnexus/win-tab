import SwiftUI

struct SwitchView: View {
    @EnvironmentObject var model: SwitchModel
    @ObservedObject private var prefs = SwitchPreferences.shared
    @ObservedObject private var style = StylePreferences.shared
    @State private var hoveredID: CGWindowID?
    @State private var hasMouseMovedSinceOpen = false
    @State private var pointer = PointerTracker()
    @State private var lastSelectionFromMouse = false
    /// Bumped on any settings change, so cached tiles redraw with the new look.
    @State private var prefsToken = 0

    /// One pointer tracker for the whole grid instead of `.onHover` per tile: crossing the gap
    /// between tiles used to end one hover and start the next (no selection in between, the
    /// tile's buttons blinking off and on). The tile under the pointer, or the nearest one when
    /// it's in a gap, lights up at once; it becomes the selection once the pointer has moved.
    private func pointerMoved(_ phase: HoverPhase) {
        guard !prefs.disableMouse, model.visible else { return }
        guard case .active(let p) = phase else {
            hoveredID = nil
            model.pointerWindowID = nil
            return
        }
        guard let id = pointer.window(at: p, among: Set(model.filteredWindows.map(\.id))) else { return }
        model.pointerWindowID = id
        if hoveredID != id { hoveredID = id }
        // A cursor resting where the picker opened must not take the default selection.
        if !hasMouseMovedSinceOpen {
            guard let anchor = pointer.anchor else { pointer.anchor = p; return }
            guard hypot(p.x - anchor.x, p.y - anchor.y) >= PointerTracker.moveToSelect else { return }
            hasMouseMovedSinceOpen = true
        }
        guard let index = model.filteredWindows.firstIndex(where: { $0.id == id }), model.selected != index else { return }
        lastSelectionFromMouse = true
        model.selected = index
    }

    private func handleTap(index: Int) {
        guard !prefs.disableMouse else { return }
        lastSelectionFromMouse = true
        model.selected = index
        model.commitAndDismiss?()
    }

    private func isPinned(_ window: WindowInfo) -> Bool {
        window.bundleID.map { prefs.pinnedBundleIDs.contains($0) } ?? false
    }

    @ViewBuilder
    private func windowBadge(for window: WindowInfo) -> some View {
        if window.isMinimized || window.isHidden || window.isCrossSpace || window.isWindowless {
            capsuleBadge(windowBadgeText(for: window))
        }
    }

    private func capsuleBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
    }

    /// Unread count the app shows on its Dock icon, mirrored onto the picker icon.
    @ViewBuilder
    private func dockBadge(for window: WindowInfo) -> some View {
        if prefs.showDockBadges, let bid = window.bundleID, let badge = model.badges[bid] {
            Text(badge)
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Capsule().fill(Color.red))
                .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                .fixedSize()
                .offset(x: 5, y: -5)
        }
    }

    @ViewBuilder
    private func numberHint(index: Int) -> some View {
        if prefs.showNumberKeyHints && !isSpaceMode && index < 9 {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 16, height: 16)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func windowBadgeText(for window: WindowInfo) -> String {
        if window.isMinimized { return "MINIMIZED" }
        if window.isHidden { return "HIDDEN" }
        if window.isWindowless { return "NO WINDOWS" }
        return window.spaceLabel?.uppercased() ?? "OTHER SPACE"
    }

    private var showHeader: Bool {
        isSpaceMode || !prefs.verticalList || prefs.verticalShowHeader || !model.filterText.isEmpty
    }

    private var isSpaceMode: Bool { model.mode == .spaces }
    private var animationsEnabled: Bool { !prefs.disableAnimations }

    private func switcherAnimation(_ animation: Animation) -> Animation? {
        animationsEnabled ? animation.speed(prefs.animationSpeed) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHeader { header }
            grid
            if prefs.showHintStrip { hintStrip }
        }
        .frame(width: model.panelSize.width, height: model.panelSize.height)
        .background {
            // SwiftUI materials don't sample behind the panel pre-Tahoe (#81).
            if #available(macOS 26.0, *) {
                if prefs.backgroundBlur != .glass { Rectangle().fill(prefs.backgroundBlur.material) }
            } else {
                VisualEffectBackdrop(material: prefs.backgroundBlur.nsMaterial, blendingMode: .behindWindow)
            }
        }
        .flatTint(style.windowTint, glass: prefs.backgroundBlur == .glass)
        .liquidGlass(prefs.backgroundBlur == .glass, cornerRadius: style.windowRadius, tint: style.windowTint)
        .clipShape(RoundedRectangle(cornerRadius: style.windowRadius, style: .continuous))
        .overlay {
            if let border = style.resolve(style.windowBorder, custom: style.windowBorderColor) {
                RoundedRectangle(cornerRadius: style.windowRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: style.windowBorderWidth)
            }
        }
        // Showing animates on the window's layer (SwitcherWindow.popIn), off the main thread.
        .opacity(model.visible ? 1 : 0)
        .onReceive(prefs.objectWillChange.merge(with: style.objectWillChange)) { prefsToken &+= 1 }
        .onChange(of: model.visible) { _, isVisible in
            if isVisible {
                pointer.anchor = nil
                hasMouseMovedSinceOpen = false
                lastSelectionFromMouse = false
                hoveredID = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !model.filterText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(model.filterText)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Spacer()
            if prefs.showWindowCount && !model.filteredWindows.isEmpty {
                Text(isSpaceMode ? "\(model.filteredWindows.count) spaces" : "\(model.filteredWindows.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 26)
    }

    private var grid: some View {
        ZStack {
            let list = model.filteredWindows
            if list.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Group {
                        if isSpaceMode || prefs.verticalList {
                            LazyVStack(spacing: 4) {
                                let slim = SwitchPreferences.compactsWindowless(mode: model.mode)
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, w in
                                    EquatableTile(key: tileKey(w, idx)) {
                                        if slim && w.isWindowless { slimRow(window: w, index: idx) } else { listRow(window: w, index: idx) }
                                    }
                                    .equatable()
                                    .modifier(TileFrameReporter(id: w.id, tracker: pointer))
                                    .id(w.id)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, showHeader ? 10 : 14)
                            .padding(.bottom, 10)
                        } else {
                            let indexed = Array(list.enumerated())
                            let compact = SwitchPreferences.compactsWindowless(mode: model.mode)
                            let tiles = compact ? indexed.filter { !$0.element.isWindowless } : indexed
                            let chips = compact ? indexed.filter { $0.element.isWindowless } : []
                            VStack(alignment: .leading, spacing: 14) {
                                if !tiles.isEmpty {
                                    LazyVGrid(columns: gridColumns, spacing: 14) {
                                        ForEach(tiles, id: \.element.id) { idx, w in
                                            EquatableTile(key: tileKey(w, idx)) { tile(window: w, index: idx, list: list) }
                                                .equatable()
                                                .modifier(TileFrameReporter(id: w.id, tracker: pointer))
                                                .id(w.id)
                                        }
                                    }
                                }
                                if !chips.isEmpty { windowlessStrip(chips) }
                            }
                            .padding(.horizontal, 22)
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                        }
                        }
                        .backgroundPreferenceValue(SelectionBoundsKey.self) { b in
                            SelectionHighlight(bounds: b, part: .fill, accent: prefs.accent.color, spring: highlightSpring)
                        }
                        .overlayPreferenceValue(SelectionBoundsKey.self) { b in
                            SelectionHighlight(bounds: b, part: .ring, accent: prefs.accent.color, spring: highlightSpring)
                        }
                        .coordinateSpace(name: PointerTracker.space)
                        .onContinuousHover(coordinateSpace: .named(PointerTracker.space), perform: pointerMoved)
                    }
                    .onChange(of: model.selected) { _, new in
                        // Skip auto-scroll when selection came from mouse hover;
                        // user is already looking at where they're pointing.
                        if lastSelectionFromMouse {
                            lastSelectionFromMouse = false
                            return
                        }
                        let cur = model.filteredWindows
                        guard cur.indices.contains(new) else { return }
                        // No anchor: scroll only when the selection is out of view. Centring on
                        // every step slid the whole grid under each Tab press.
                        withAnimation(switcherAnimation(.easeOut(duration: 0.14))) {
                            proxy.scrollTo(cur[new].id)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.filterText.isEmpty ? "rectangle.stack" : "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(model.filterText.isEmpty ? "No windows" : "No matches")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .transition(.scale(scale: 0.98).combined(with: .opacity))
    }

    private var hintStrip: some View {
        HStack(spacing: 18) {
            hint("↵", isSpaceMode ? "switch space" : "switch")
            hint(navKey, "navigate")
            if prefs.shiftTapReverses { hint("⇧", "reverse") }
            if !isSpaceMode { hint(closeKey, "close") }
            if prefs.typeToFilter { hint("type", "filter") }
            hint("esc", "cancel")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18))
    }

    private var navKey: String {
        if prefs.verticalList || isSpaceMode {
            return prefs.vimNavigation ? "↑↓ / jk" : "↑↓"
        }
        return prefs.vimNavigation ? "←↑↓→ / hjkl" : "←↑↓→"
    }

    private var closeKey: String {
        (model.stickySession || !prefs.typeToFilter) ? "⌘W" : "⇧⌘W"
    }

    private func stoplights(for window: WindowInfo) -> some View {
        HStack(spacing: 4) {
            stoplight(color: Color(red: 1.0, green: 0.36, blue: 0.34), symbol: "xmark") {
                model.close(window)
            }
            stoplight(color: Color(red: 1.0, green: 0.74, blue: 0.20), symbol: "minus") {
                WindowMinimizer.minimize(window)
            }
            stoplight(color: Color(red: 0.30, green: 0.78, blue: 0.34), symbol: "plus") {
                WindowZoomer.zoom(window)
            }
        }
        .opacity(prefs.disableMouse ? 0 : 1)
        .allowsHitTesting(!prefs.disableMouse)
    }

    private func pinButton(for window: WindowInfo) -> some View {
        let bid = window.bundleID
        let isPinned = bid.map { prefs.pinnedBundleIDs.contains($0) } ?? false
        return Button {
            guard let bid else { return }
            if isPinned { prefs.pinnedBundleIDs.remove(bid) }
            else { prefs.pinnedBundleIDs.insert(bid) }
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isPinned ? prefs.accent.color : Color.white.opacity(0.75))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .opacity(prefs.disableMouse ? 0 : 1)
        .allowsHitTesting(!prefs.disableMouse)
    }

    /// Hides the app so macOS throttles it (App Nap); it keeps running.
    private func backgroundButton(for window: WindowInfo) -> some View {
        Button {
            model.sendToBackground(window)
        } label: {
            Image(systemName: "moon.zzz")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(window.isHidden ? 0.45 : 0.85))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .help("Run \(window.appName) in the background: hide it so macOS can slow it down; it keeps running")
        .opacity(prefs.disableMouse ? 0 : 1)
        .allowsHitTesting(!prefs.disableMouse)
    }

    /// Closes every window of the app and keeps it running, so it moves to NO WINDOWS.
    private func closeAllButton(for window: WindowInfo) -> some View {
        Button {
            model.closeAllWindows(of: window)
        } label: {
            Image(systemName: "rectangle.badge.xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .help("Close all \(window.appName) windows, keep it running")
        .opacity(prefs.disableMouse ? 0 : 1)
        .allowsHitTesting(!prefs.disableMouse)
    }

    private func stoplight(color: Color, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.black.opacity(0.55))
            }
        }
        .buttonStyle(.plain)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .help(label)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: prefs.gridColumns)
    }

    private func tile(window: WindowInfo, index: Int, list: [WindowInfo]) -> some View {
        let selected = index == model.selected
        let hovered = hoveredID == window.id
        let icon = appIcon(for: window)

        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                ZStack {
                    Color.black.opacity(0.22)
                    if prefs.showThumbnails, let img = model.thumbnails[window.id] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    } else if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 56, height: 56)
                            .opacity(0.55)
                            .scaleEffect(selected ? 1.05 : 1.0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: prefs.showThumbnails ? prefs.thumbnailHeight : SwitchPreferences.compactThumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if prefs.showStoplights && !window.isWindowless {
                        stoplights(for: window).padding(7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !window.isWindowless && (isPinned(window) || hovered) {
                        HStack(spacing: 4) {
                            if hovered { backgroundButton(for: window); closeAllButton(for: window) }
                            pinButton(for: window)
                        }
                        .padding(7)
                    }
                }
                .animation(switcherAnimation(.easeOut(duration: 0.18)), value: model.thumbnails[window.id] != nil)

                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: prefs.appIconSize, height: prefs.appIconSize)
                        .overlay(alignment: .topTrailing) { dockBadge(for: window) }
                        .scaleEffect(selected ? 1.06 : 1.0)
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1)
                        .padding(7)
                }

                HStack(spacing: 0) {
                    Spacer()
                    VStack {
                        Spacer()
                        windowBadge(for: window).padding(7)
                    }
                }
            }

            HStack(spacing: 6) {
                let titleFirst = prefs.showTitleFirst && !window.title.isEmpty
                numberHint(index: index)
                Text(titleFirst ? window.title : window.appName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !window.title.isEmpty {
                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text(titleFirst ? window.appName : window.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
        .padding(9)
        .modifier(SelectionChrome(selected: selected, hovered: hovered, cornerRadius: 9, accent: prefs.accent.color, animationsEnabled: animationsEnabled, animationSpeed: prefs.animationSpeed))
        .contentShape(Rectangle())
        .onTapGesture { handleTap(index: index) }
    }

    /// Apps with no windows, as small icons under the tiles so they don't take a full tile each.
    private func windowlessStrip(_ chips: [(offset: Int, element: WindowInfo)]) -> some View {
        let chip = SwitcherPanelSize.stripChip
        return VStack(alignment: .leading, spacing: 0) {
            Text("NO WINDOWS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .frame(height: SwitcherPanelSize.stripHeader, alignment: .topLeading)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: chip.width, maximum: chip.width), spacing: SwitcherPanelSize.stripSpacing)],
                      alignment: .leading, spacing: SwitcherPanelSize.stripSpacing) {
                ForEach(chips, id: \.element.id) { idx, w in
                    EquatableTile(key: tileKey(w, idx)) { windowlessChip(window: w, index: idx) }
                        .equatable()
                        .modifier(TileFrameReporter(id: w.id, tracker: pointer))
                        .id(w.id)
                }
            }
        }
    }

    private func windowlessChip(window: WindowInfo, index: Int) -> some View {
        let selected = index == model.selected
        let hovered = hoveredID == window.id
        let chip = SwitcherPanelSize.stripChip
        return VStack(spacing: 4) {
            if let icon = appIcon(for: window) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .overlay(alignment: .topTrailing) { dockBadge(for: window) }
                    .scaleEffect(selected ? 1.08 : 1.0)
            }
            Text(window.appName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: chip.width - 10)
        }
        .frame(width: chip.width, height: chip.height)
        .modifier(SelectionChrome(selected: selected, hovered: hovered, cornerRadius: 8, accent: prefs.accent.color, animationsEnabled: animationsEnabled, animationSpeed: prefs.animationSpeed))
        .contentShape(Rectangle())
        .help(window.appName)
        .onTapGesture { handleTap(index: index) }
    }

    /// A windowless app in the list: one short line, no preview.
    private func slimRow(window: WindowInfo, index: Int) -> some View {
        let selected = index == model.selected
        let hovered = hoveredID == window.id
        return HStack(spacing: 9) {
            numberHint(index: index)
            if let icon = appIcon(for: window) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    .overlay(alignment: .topTrailing) { dockBadge(for: window).scaleEffect(0.8) }
            }
            Text(window.appName).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 6)
            Text("NO WINDOWS").font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: SwitcherPanelSize.slimRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SelectionChrome(selected: selected, hovered: hovered, cornerRadius: 8, accent: prefs.accent.color, animationsEnabled: animationsEnabled, animationSpeed: prefs.animationSpeed))
        .contentShape(Rectangle())
        .onTapGesture { handleTap(index: index) }
    }

    private func listRow(window: WindowInfo, index: Int) -> some View {
        let selected = index == model.selected
        let hovered = hoveredID == window.id
        let icon = appIcon(for: window)

        return HStack(spacing: 11) {
            numberHint(index: index)
            ZStack {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: prefs.appIconSize, height: prefs.appIconSize)
                        .overlay(alignment: .topTrailing) { dockBadge(for: window) }
                        .scaleEffect(selected ? 1.08 : 1.0)
                } else {
                    Color.clear.frame(width: prefs.appIconSize, height: prefs.appIconSize)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                let titleFirst = prefs.showTitleFirst && !window.title.isEmpty
                Text(titleFirst ? window.title : window.appName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !window.title.isEmpty {
                    Text(titleFirst ? window.appName : window.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if !isSpaceMode && prefs.showStoplights && prefs.verticalShowStoplights && !window.isWindowless {
                stoplights(for: window)
                    .opacity(hovered ? 1 : 0.45)
            }
            if !isSpaceMode && !window.isWindowless && hovered {
                backgroundButton(for: window)
                closeAllButton(for: window)
            }
            if !isSpaceMode && !window.isWindowless && (isPinned(window) || hovered) {
                pinButton(for: window)
                    .opacity(hovered ? 1 : 0.8)
            }
            if isSpaceMode {
                if window.spaceLabel == "Current" {
                    capsuleBadge("CURRENT")
                }
            } else {
                windowBadge(for: window)
            }
            if prefs.showThumbnails && prefs.verticalShowPreview {
                Group {
                    if let img = model.thumbnails[window.id] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 88, height: 50)
                    } else {
                        Color.black.opacity(0.22)
                            .frame(width: 88, height: 50)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SelectionChrome(selected: selected, hovered: hovered, cornerRadius: 8, accent: prefs.accent.color, animationsEnabled: animationsEnabled, animationSpeed: prefs.animationSpeed))
        .contentShape(Rectangle())
        .onTapGesture { handleTap(index: index) }
    }

    /// The highlight sliding between tiles; set once on the grid so tiles don't depend on the selection index.

    /// The highlight's spring (Core Animation): the user's speed for keys; following the mouse it
    /// glides, sped up at most 1.5× so it still reads as a slide.
    private var highlightSpring: (response: Double, damping: Double)? {
        guard animationsEnabled else { return nil }
        return lastSelectionFromMouse ? (0.2 / min(prefs.animationSpeed, 1.5), 0.86) : (0.15 / prefs.animationSpeed, 0.9)
    }

    /// Everything a tile draws from outside itself.
    private func tileKey(_ w: WindowInfo, _ index: Int) -> TileKey {
        TileKey(window: w, index: index, selected: index == model.selected, hovered: hoveredID == w.id,
                thumbnail: model.thumbnails[w.id].map(ObjectIdentifier.init), badge: w.bundleID.flatMap { model.badges[$0] },
                prefs: prefsToken)
    }

    private func appIcon(for window: WindowInfo) -> NSImage? {
        let key = window.bundleID ?? "pid:\(window.pid)"
        if let cached = Self.iconCache[key] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: window.pid)?.icon.map(NSImage.flattenedIcon) else { return nil }
        if Self.iconCache.count > 256 { Self.iconCache.removeAll() }
        Self.iconCache[key] = icon
        return icon
    }

    private static var iconCache: [String: NSImage] = [:]
}

/// Hover fill on a tile, and where the selection highlight goes: the selected tile reports its
/// bounds and the grid draws one highlight there (see `SelectionHighlight`).
private struct SelectionChrome: ViewModifier {
    let selected: Bool
    let hovered: Bool
    let cornerRadius: CGFloat
    let accent: Color
    let animationsEnabled: Bool
    let animationSpeed: Double

    func body(content: Content) -> some View {
        content
            .background {
                if hovered && !selected {
                    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    shape.fill(accent.opacity(0.16)).overlay(shape.stroke(accent.opacity(0.45), lineWidth: 1))
                }
            }
            .anchorPreference(key: SelectionBoundsKey.self, value: .bounds) { selected ? SelectionBounds(anchor: $0, radius: cornerRadius) : nil }
    }
}

struct SelectionBounds {
    let anchor: Anchor<CGRect>
    let radius: CGFloat
}

struct SelectionBoundsKey: PreferenceKey {
    static let defaultValue: SelectionBounds? = nil
    static func reduce(value: inout SelectionBounds?, nextValue: () -> SelectionBounds?) { value = value ?? nextValue() }
}

/// The selection highlight, drawn once over (ring) or under (fill) the grid at the selected
/// tile's bounds. SwiftUI hands over the new rect once per selection change; a Core Animation
/// spring moves the layer on the render server, so the slide costs the main thread nothing
/// (a SwiftUI animation re-renders on the main thread every frame, and a matched-geometry pair
/// inside the tiles also re-laid out the grid and re-drew their text).
struct SelectionHighlight: View {
    enum Part { case fill, ring }
    let bounds: SelectionBounds?
    let part: Part
    let accent: Color
    /// (response, damping) of the spring, or nil to jump.
    let spring: (response: Double, damping: Double)?
    @ObservedObject private var style = StylePreferences.shared

    var body: some View {
        GeometryReader { proxy in
            SelectionLayerView(rect: bounds.map { proxy[$0.anchor] }, radius: bounds?.radius ?? 8, look: look, spring: spring)
        }
        .allowsHitTesting(false)
    }

    private var look: SelectionLayerView.Look {
        let color = NSColor(accent)
        switch part {
        case .fill:
            guard style.windowSelection != .outline else { return .none }
            return .fill(color.withAlphaComponent(style.windowSelection == .solid ? 0.55 : 0.22), glow: style.windowSelection == .glow ? color : nil)
        case .ring:
            guard style.windowSelection != .solid else { return .none }
            return .ring(color.withAlphaComponent(style.windowSelection == .soft ? 0.7 : 1), width: style.windowSelection == .soft ? 1 : 2)
        }
    }
}

private struct SelectionLayerView: NSViewRepresentable {
    enum Look: Equatable {
        case none
        case fill(NSColor, glow: NSColor?)
        case ring(NSColor, width: CGFloat)
    }

    let rect: CGRect?
    let radius: CGFloat
    let look: Look
    let spring: (response: Double, damping: Double)?

    func makeNSView(context: Context) -> HighlightHost { HighlightHost() }

    func updateNSView(_ view: HighlightHost, context: Context) {
        view.apply(look: look, radius: radius)
        view.move(to: rect, spring: spring)
    }

    final class HighlightHost: NSView {
        private let shape = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            shape.cornerCurve = .continuous
            shape.isHidden = true
            layer?.addSublayer(shape)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(look: Look, radius: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.cornerRadius = radius
            switch look {
            case .none:
                shape.backgroundColor = nil
                shape.borderWidth = 0
                shape.shadowOpacity = 0
            case .fill(let color, let glow):
                shape.backgroundColor = color.cgColor
                shape.borderWidth = 0
                shape.shadowColor = glow?.cgColor
                shape.shadowRadius = 10
                shape.shadowOffset = .zero
                shape.shadowOpacity = glow == nil ? 0 : 0.8
            case .ring(let color, let width):
                shape.backgroundColor = nil
                shape.borderColor = color.cgColor
                shape.borderWidth = width
                shape.shadowOpacity = 0
            }
            CATransaction.commit()
        }

        func move(to rect: CGRect?, spring: (response: Double, damping: Double)?) {
            guard let rect, let host = layer else {
                shape.isHidden = true
                return
            }
            // The backing layer of a flipped view may or may not be flipped itself.
            let target = host.isGeometryFlipped ? rect : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
            let wasHidden = shape.isHidden
            let from = shape.presentation() ?? shape
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let spring, !wasHidden, from.frame != target {
                for (key, old, new) in [("position", NSValue(point: from.position), NSValue(point: CGPoint(x: target.midX, y: target.midY))),
                                        ("bounds.size", NSValue(size: from.bounds.size), NSValue(size: target.size))] {
                    let a = CASpringAnimation(keyPath: key)
                    a.stiffness = pow(2 * .pi / spring.response, 2)
                    a.damping = 4 * .pi * spring.damping / spring.response
                    a.fromValue = old
                    a.toValue = new
                    a.duration = a.settlingDuration
                    shape.add(a, forKey: key)
                }
            }
            shape.frame = target
            shape.isHidden = false
            CATransaction.commit()
        }
    }
}

extension View {
    /// Liquid Glass backdrop in a rounded rect on macOS 26+, no-op otherwise (the material fallback
    /// applies). A visible `tint` colours the glass itself rather than a layer over it.
    @ViewBuilder
    func liquidGlass(_ enabled: Bool, cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *), enabled {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let base: Glass = StylePreferences.shared.glass == .clear ? .clear : .regular
            if let tint, tint.isVisible {
                glassEffect(base.tint(tint), in: shape)
            } else {
                glassEffect(base, in: shape)
            }
        } else {
            self
        }
    }

    /// A flat tint over a background, for everything but Liquid Glass (which takes it as its own tint).
    func flatTint(_ tint: Color, glass: Bool) -> some View {
        background(glass && Color.glassAvailable ? Color.clear : tint)
    }
}

extension Color {
    /// Not fully transparent.
    var isVisible: Bool { (NSColor(self).usingColorSpace(.sRGB)?.alphaComponent ?? 0) > 0.01 }

    static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// What a picker tile depends on. Equal keys skip rebuilding the tile, so a selection step
/// redraws the two tiles it touches instead of the whole grid.
private struct TileKey: Equatable {
    let window: WindowInfo
    let index: Int
    let selected: Bool
    let hovered: Bool
    let thumbnail: ObjectIdentifier?
    let badge: String?
    let prefs: Int
}

private struct EquatableTile<Content: View>: View, Equatable {
    let key: TileKey
    @ViewBuilder let content: () -> Content

    static func == (a: Self, b: Self) -> Bool { a.key == b.key }

    var body: some View { content() }
}

/// Tile frames in the picker's scroll content, kept out of SwiftUI state: they change on
/// layout, not on pointer moves, and must not redraw the grid.
final class PointerTracker {
    static let space = "switcher.grid"
    /// How far the pointer must move after the picker opens before hovering selects.
    static let moveToSelect: CGFloat = 3
    /// A pointer this close to a tile (a gap or the margin) still counts as on it.
    private static let reach: CGFloat = 18

    var frames: [CGWindowID: CGRect] = [:]
    var anchor: CGPoint?

    /// The listed window under `p`, or the nearest within reach. Frames of windows from earlier
    /// opens stay in `frames` and can overlap today's tiles, so only `live` ones count.
    func window(at p: CGPoint, among live: Set<CGWindowID>) -> CGWindowID? {
        frames = frames.filter { live.contains($0.key) }
        if let hit = frames.first(where: { $0.value.contains(p) }) { return hit.key }
        let near = frames.map { (id: $0.key, d: Self.distance(p, $0.value)) }.min { $0.d < $1.d }
        return near.flatMap { $0.d <= Self.reach ? $0.id : nil }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }
}

private struct TileFrameReporter: ViewModifier {
    let id: CGWindowID
    let tracker: PointerTracker

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PointerTracker.space)) } action: { tracker.frames[id] = $0 }
    }
}
