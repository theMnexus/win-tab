import AppKit
import SwiftUI

/// One slot on win-tab's Dock: an app mirrored from Apple's Dock, or an item of your own arrangement.
struct CustomDockItem: Identifiable, Equatable {
    enum Content: Equatable {
        case app
        case folder(URL)
        case group([URL])
        case spacer
        case divider
        case widget(DockWidgetKind)
        case stack([DockWidgetKind])
        /// Always last, after a divider, like Apple's Dock; `full` picks the icon.
        case trash(full: Bool)
    }

    let id: String
    let title: String
    let url: URL?
    let icon: NSImage
    let isRunning: Bool
    let badge: String?
    let content: Content
    /// The saved entry this came from; nil when mirrored from Apple's Dock or added because it's running.
    var entryID: UUID?
    var groupIcons: [NSImage] = []
    let source: DockAX.Item

    /// Icons grow under the pointer; widgets, spacers and dividers keep their size.
    var magnifies: Bool {
        switch content {
        case .app, .folder, .group, .trash: return true
        case .spacer, .divider, .widget, .stack: return false
        }
    }

    var showsNowPlaying: Bool {
        switch content {
        case .widget(let kind): return kind == .nowPlaying
        case .stack(let kinds): return kinds.contains(.nowPlaying)
        default: return false
        }
    }

    /// Length along the Dock, in icon sizes.
    func units(vertical: Bool) -> CGFloat {
        switch content {
        case .app, .folder, .group, .trash: return 1
        case .spacer: return 0.5
        case .divider: return 0.2
        case .widget(let kind): return kind.units(vertical: vertical)
        case .stack(let kinds): return kinds.map { $0.units(vertical: vertical) }.max() ?? 1
        }
    }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.isRunning == b.isRunning && a.badge == b.badge && a.title == b.title
            && a.content == b.content && a.entryID == b.entryID && a.groupIcons.count == b.groupIcons.count
    }
}

@MainActor
final class CustomDockModel: ObservableObject {
    @Published var items: [CustomDockItem] = []
}

/// All geometry in the panel's local, top-left coordinates, shared by the view (drawing) and
/// the controller (panel size, hover anchors), so both always agree.
///
/// Magnification works like Apple's Dock: magnified icons push their neighbours apart (gaps stay
/// constant, nothing overlaps) and the spot under the pointer stays put while the growth spreads
/// to both sides, so hovering never makes icons slide away from the cursor. Items can have
/// different lengths (widgets, spacers, dividers), and only icons magnify.
struct CustomDockLayout {
    static let indicatorSpace: CGFloat = 7
    /// How far a lifted icon rises, in icon sizes.
    static let liftRise: CGFloat = 0.32
    /// How high an app asking for attention hops, in icon heights.
    static let attentionRise: CGFloat = 0.5
    static let liftScale: CGFloat = 1.12

    struct Frame { let center: CGFloat; let scale: CGFloat }

    /// The user-tunable spacing around items.
    struct Metrics: Hashable {
        var padding: CGFloat = 8
        var spacing: CGFloat = 8
        /// Magnification reach either side, in icon sizes.
        var spread: CGFloat = 2.5
        /// Extra room across the Dock for effects that rise out of it (lift, bounce).
        var rise: CGFloat = 0
        /// Grip at the start of the bar for dragging the Dock.
        var handle: CGFloat = 0
        /// Size a hovered icon grows to with Lift and Glow.
        var hoverZoom: CGFloat = 1.12
    }

    static let handleLength: CGFloat = 10

    let edge: ScreenEdge
    let iconSize: CGFloat
    let maxScale: CGFloat
    let metrics: Metrics
    /// Resting slot length of each item along the Dock, its insets included.
    let lengths: [CGFloat]
    /// Room left empty on each side of an item inside its slot (the widget gap).
    let insets: [CGFloat]
    let magnifies: [Bool]
    /// Room at each end for the bar to stretch into while magnified.
    let endRoom: CGFloat
    /// Resting centers along the Dock, endRoom included.
    let rests: [CGFloat]

    var padding: CGFloat { metrics.padding }
    var spacing: CGFloat { metrics.spacing }

    private struct Key: Hashable {
        let edge: ScreenEdge, iconSize: CGFloat, maxScale: CGFloat, metrics: Metrics, lengths: [CGFloat], insets: [CGFloat], magnifies: [Bool]
    }
    /// A few layouts (one per edge in use, since each display can sit on its own edge).
    @MainActor private static var cache: [Key: CustomDockLayout] = [:]

    /// Built once per change of items or settings: every hover frame asks for it, and `endRoom`
    /// sweeps the whole Dock.
    @MainActor
    static func make(prefs: SwitchPreferences, items: [CustomDockItem], edge: ScreenEdge? = nil) -> CustomDockLayout {
        let edge = edge ?? prefs.customDockEdge, size = prefs.customDockIconSize
        let effect = prefs.customDockHoverEffect
        var metrics = Metrics(padding: prefs.customDockPadding, spacing: prefs.customDockSpacing, spread: prefs.customDockSpread,
                              handle: prefs.customDockGripMode == .never ? 0 : handleLength, hoverZoom: prefs.customDockHoverZoom)
        if effect == .lift || effect == .glow || prefs.customDockClickBounce {
            metrics.rise = size * liftRise + size * (metrics.hoverZoom - 1)
        }
        // Room for an app asking for attention to hop (`CustomDockCanvas.setAttention`).
        metrics.rise = max(metrics.rise, size * attentionRise)
        let gap = CGFloat(prefs.customDockWidgetGap)
        let insets = items.map { item -> CGFloat in
            switch item.content {
            case .widget, .stack: return gap
            default: return 0
            }
        }
        let key = Key(edge: edge, iconSize: size,
                      maxScale: effect == .magnify ? max(1, prefs.customDockMagnifiedSize / size) : 1,
                      metrics: metrics,
                      lengths: zip(items, insets).map { $0.units(vertical: edge.isVertical) * size + $1 * 2 },
                      insets: insets,
                      magnifies: items.map(\.magnifies))
        if let hit = cache[key] { return hit }
        let layout = CustomDockLayout(edge: key.edge, iconSize: key.iconSize, maxScale: key.maxScale, metrics: key.metrics,
                                      lengths: key.lengths, insets: key.insets, magnifies: key.magnifies)
        if cache.count > 8 { cache.removeAll() }
        cache[key] = layout
        return layout
    }

    init(edge: ScreenEdge, iconSize: CGFloat, maxScale: CGFloat, metrics: Metrics = Metrics(), lengths: [CGFloat],
         insets: [CGFloat]? = nil, magnifies: [Bool]) {
        self.insets = insets ?? lengths.map { _ in 0 }
        self.edge = edge
        self.iconSize = iconSize
        self.maxScale = maxScale
        self.metrics = metrics
        self.lengths = lengths
        self.magnifies = magnifies
        let base = Self.restCenters(lengths: lengths, start: metrics.padding + metrics.handle, spacing: metrics.spacing)
        let room = Self.maxStretch(rests: base, lengths: lengths, magnifies: magnifies, iconSize: iconSize, maxScale: maxScale, metrics: metrics)
        endRoom = room
        rests = base.map { $0 + room }
    }

    var count: Int { lengths.count }

    private static func restCenters(lengths: [CGFloat], start: CGFloat, spacing: CGFloat) -> [CGFloat] {
        var out: [CGFloat] = []
        var cursor = start
        for l in lengths {
            out.append(cursor + l / 2)
            cursor += l + spacing
        }
        return out
    }

    /// The glass bar at rest.
    var barThickness: CGFloat { iconSize + padding * 2 + Self.indicatorSpace }
    var barLength: CGFloat {
        guard count > 0 else { return iconSize + padding * 2 }
        return lengths.reduce(0, +) + CGFloat(count - 1) * spacing + padding * 2
    }
    var panelThickness: CGFloat { barThickness + max(iconSize * (maxScale - 1), metrics.rise) }
    /// Room before the bar where the drag grip slides out on hover (the bar takes no space for it otherwise).
    var panelLength: CGFloat { barLength + endRoom * 2 + metrics.handle }

    var panelSize: CGSize {
        edge.isVertical ? CGSize(width: panelThickness, height: panelLength) : CGSize(width: panelLength, height: panelThickness)
    }

    /// Resting item center across the Dock (items hug the screen edge).
    var across: CGFloat {
        switch edge {
        case .bottom, .right: return panelThickness - padding - Self.indicatorSpace - iconSize / 2
        case .top, .left: return padding + Self.indicatorSpace + iconSize / 2
        }
    }

    /// Unit vector across the Dock pointing away from the screen edge.
    var awayFromEdge: CGPoint {
        switch edge {
        case .bottom: return CGPoint(x: 0, y: -1)
        case .top: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: 1, y: 0)
        case .right: return CGPoint(x: -1, y: 0)
        }
    }

    func point(along a: CGFloat, across c: CGFloat) -> CGPoint { edge.isVertical ? CGPoint(x: c, y: a) : CGPoint(x: a, y: c) }

    /// Item size at rest: its length along the Dock, the icon size across.
    /// Item size at rest: its content length along the Dock (slot minus insets), the icon size across.
    func itemSize(_ i: Int) -> CGSize {
        let l = lengths[i] - insets[i] * 2
        return edge.isVertical ? CGSize(width: iconSize, height: l) : CGSize(width: l, height: iconSize)
    }

    /// The drag grip at the start of the bar, for a bar that starts at `barStart`.
    func handleRect(barStart: CGFloat) -> CGRect {
        let a = barStart - metrics.handle + 1, l = metrics.handle
        let c0 = across - iconSize / 2
        return edge.isVertical ? CGRect(x: c0, y: a, width: iconSize, height: l) : CGRect(x: a, y: c0, width: l, height: iconSize)
    }

    func itemRect(_ i: Int) -> CGRect {
        let c = point(along: rests[i], across: across), s = itemSize(i)
        return CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
    }

    /// Icons grow away from the screen edge.
    var growAnchor: UnitPoint {
        switch edge {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// Running dot, between the icon and the screen edge.
    var indicatorAcross: CGFloat {
        let off = iconSize / 2 + Self.indicatorSpace / 2 + 1
        switch edge {
        case .bottom, .right: return across + off
        case .top, .left: return across - off
        }
    }

    /// macOS-style smoothstep falloff over `spread` icons, measured on resting positions so it can't feed back.
    private static func scale(restCenter: CGFloat, pointer: CGFloat?, iconSize: CGFloat, maxScale: CGFloat, spread: CGFloat) -> CGFloat {
        guard maxScale > 1, let p = pointer else { return 1 }
        let t = max(0, 1 - abs(p - restCenter) / (iconSize * spread))
        return 1 + (maxScale - 1) * (t * t * (3 - 2 * t))
    }

    /// Item centers and scales for a pointer position, plus the bar's extent along the Dock.
    /// `amount` 0…1 eases the magnification in and out (0 = at rest, 1 = full size).
    func frames(pointerAlong p: CGFloat?, amount: CGFloat = 1) -> (items: [Frame], barStart: CGFloat, barEnd: CGFloat) {
        let restBar = (endRoom + metrics.handle, endRoom + metrics.handle + barLength)
        let peak = 1 + (maxScale - 1) * min(max(amount, 0), 1)
        guard count > 0, peak > 1, let p else {
            return (rests.map { Frame(center: $0, scale: 1) }, restBar.0, restBar.1)
        }
        let r = Self.stretch(rests: rests, lengths: lengths, magnifies: magnifies, pointer: p, iconSize: iconSize, maxScale: peak, metrics: metrics)
        let last = count - 1
        return (zip(r.centers, r.scales).map { Frame(center: $0, scale: $1) },
                r.centers[0] - lengths[0] * r.scales[0] / 2 - padding,
                r.centers[last] + lengths[last] * r.scales[last] / 2 + padding)
    }

    private static func stretch(rests: [CGFloat], lengths: [CGFloat], magnifies: [Bool], pointer p: CGFloat,
                                iconSize s: CGFloat, maxScale: CGFloat, metrics: Metrics) -> (centers: [CGFloat], scales: [CGFloat]) {
        let g = metrics.spacing, n = rests.count
        let scales = (0..<n).map { magnifies[$0] ? scale(restCenter: rests[$0], pointer: p, iconSize: s, maxScale: maxScale, spread: metrics.spread) : 1 }
        let widths = (0..<n).map { lengths[$0] * scales[$0] }
        var packed = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            packed[i] = i == 0 ? widths[0] / 2 : packed[i - 1] + widths[i - 1] / 2 + g + widths[i] / 2
        }
        // Keep the spot under the pointer fixed: same fraction through the same slot.
        let slotStart = { (i: Int) in rests[i] - lengths[i] / 2 - g / 2 }
        let q = min(max(p, slotStart(0)), rests[n - 1] + lengths[n - 1] / 2 + g / 2)
        let k = (0..<n).last { slotStart($0) <= q } ?? 0
        let f = (q - slotStart(k)) / max(lengths[k] + g, 1)
        let e = packed[k] - widths[k] / 2 - g / 2 + f * (widths[k] + g)
        let shift = q - e
        return (packed.map { $0 + shift }, scales)
    }

    /// Farthest the bar reaches past its resting ends, over every pointer position.
    private static func maxStretch(rests: [CGFloat], lengths: [CGFloat], magnifies: [Bool], iconSize s: CGFloat, maxScale: CGFloat, metrics: Metrics) -> CGFloat {
        let n = rests.count
        guard n > 0, maxScale > 1, magnifies.contains(true) else { return 0 }
        let first = rests[0] - lengths[0] / 2, last = rests[n - 1] + lengths[n - 1] / 2
        var reach: CGFloat = 0
        var p = first - metrics.spacing
        while p <= last + metrics.spacing {
            let r = stretch(rests: rests, lengths: lengths, magnifies: magnifies, pointer: p, iconSize: s, maxScale: maxScale, metrics: metrics)
            let start = r.centers[0] - lengths[0] * r.scales[0] / 2
            let end = r.centers[n - 1] + lengths[n - 1] * r.scales[n - 1] / 2
            reach = max(reach, first - start, end - last)
            p += s / 4
        }
        return ceil(reach) + 2
    }

    #if DEBUG
    /// Regression check for mixed-length magnification: no overlaps, the bar stays inside the
    /// panel, only icons scale, and every resting center maps back to its item. Returns failures.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        let s: CGFloat = 48
        let cases: [(String, [CGFloat], [Bool])] = [
            ("icons", [1, 1, 1, 1, 1].map { $0 * s }, [true, true, true, true, true]),
            ("mixed", [1, 0.2, 4, 1, 0.5, 1, 1].map { $0 * s }, [true, false, false, true, false, true, true]),
            ("widget-first", [2, 1, 1].map { $0 * s }, [false, true, true]),
            ("single", [s], [true]),
        ]
        let metricsCases = [Metrics(), Metrics(padding: 3, spacing: 0, spread: 1.5), Metrics(padding: 20, spacing: 24, spread: 5)]
        for metrics in metricsCases {
            for edge in [ScreenEdge.bottom, .left] {
                for (name, lengths, magnifies) in cases {
                    let l = CustomDockLayout(edge: edge, iconSize: s, maxScale: 1.6, metrics: metrics, lengths: lengths, magnifies: magnifies)
                    for i in 0..<l.count where l.index(atAlong: l.rests[i]) != i {
                        failures.append("\(name): index(atAlong: rest[\(i)]) != \(i)")
                    }
                    var p = l.endRoom - s
                    while p <= l.endRoom + l.barLength + s {
                        let f = l.frames(pointerAlong: p)
                        for i in 0..<l.count {
                            if !magnifies[i] && f.items[i].scale != 1 { failures.append("\(name): item \(i) scaled at p=\(p)") }
                            guard i + 1 < l.count else { continue }
                            let end = f.items[i].center + lengths[i] * f.items[i].scale / 2
                            let next = f.items[i + 1].center - lengths[i + 1] * f.items[i + 1].scale / 2
                            if next - end < metrics.spacing - 0.01 { failures.append("\(name): items \(i),\(i + 1) overlap at p=\(p)") }
                        }
                        if f.barStart < -0.5 || f.barEnd > l.panelLength + 0.5 {
                            failures.append("\(name) \(edge): bar \(f.barStart)...\(f.barEnd) outside 0...\(l.panelLength) at p=\(p)")
                        }
                        p += 3
                    }
                }
            }
        }
        return failures
    }
    #endif

    /// Item under a point along the Dock (resting slots), if any.
    func index(atAlong p: CGFloat) -> Int? {
        (0..<count).first { abs(p - rests[$0]) <= lengths[$0] / 2 + spacing / 2 }
    }

    func alongComponent(_ p: CGPoint) -> CGFloat { edge.isVertical ? p.y : p.x }

    /// Where the pointer counts as "on the Dock": the whole length, bar plus magnified icons across.
    var hoverRect: CGRect {
        let a0 = endRoom, a1 = endRoom + metrics.handle + barLength
        return edge.isVertical ? CGRect(x: 0, y: a0, width: panelThickness, height: a1 - a0)
            : CGRect(x: a0, y: 0, width: a1 - a0, height: panelThickness)
    }

    /// The bar rect for an extent along the Dock.
    func barRect(start: CGFloat, end: CGFloat) -> CGRect {
        switch edge {
        case .bottom: return CGRect(x: start, y: panelThickness - barThickness, width: end - start, height: barThickness)
        case .top: return CGRect(x: start, y: 0, width: end - start, height: barThickness)
        case .left: return CGRect(x: 0, y: start, width: barThickness, height: end - start)
        case .right: return CGRect(x: panelThickness - barThickness, y: start, width: barThickness, height: end - start)
        }
    }
}

/// Where a dragged Dock item lands.
enum CustomDockDrop: Equatable {
    /// Before the item at this index (count = at the end).
    case insert(Int)
    /// Onto the Trash: take it off the Dock.
    case remove
    /// Onto this app or group, making or growing a group.
    case group(Int)
}

struct DockFace: View, Equatable {
    let item: CustomDockItem
    let size: CGSize
    let side: CGFloat
    let vertical: Bool
    var showBadges = true
    /// Taps on a widget outside its own buttons (opens its app).
    var onTap: (() -> Void)?

    static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.size == b.size && a.side == b.side && a.vertical == b.vertical && a.showBadges == b.showBadges
    }

    var body: some View {
        content.background {
            if onTap != nil { Color.clear.contentShape(Rectangle()).onTapGesture { onTap?() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.content {
        case .app, .folder, .trash:
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .overlay(alignment: .topTrailing) { badge }
        case .group:
            groupTile(item.groupIcons)
        case .spacer:
            Color.clear
        case .divider:
            Rectangle()
                .fill(Color.primary.opacity(0.25))
                .frame(width: vertical ? side * 0.8 : 1, height: vertical ? 1 : side * 0.8)
        case .widget(let kind):
            DockWidgetView(kind: kind, size: size, vertical: vertical)
        case .stack(let kinds):
            DockSmartStackView(kinds: kinds, size: size, vertical: vertical)
        }
    }

    @ViewBuilder
    private var badge: some View {
        if showBadges, let badge = item.badge {
            Text(badge)
                .font(.system(size: max(9, side * 0.2), weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: side * 0.34, minHeight: side * 0.34)
                .background(Capsule().fill(Color.red))
                .fixedSize()
                .offset(x: 4, y: -4)
        }
    }

    /// A group shows its first four apps in a 2×2 grid, like a folder on iOS.
    private func groupTile(_ icons: [NSImage]) -> some View {
        let inner = side * 0.36, gap = side * 0.06
        return RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
            .fill(Color.primary.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .overlay {
                VStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<2, id: \.self) { col in
                                let i = row * 2 + col
                                if icons.indices.contains(i) {
                                    Image(nsImage: icons[i]).resizable().interpolation(.high).frame(width: inner, height: inner)
                                } else {
                                    Color.clear.frame(width: inner, height: inner)
                                }
                            }
                        }
                    }
                }
            }
    }
}

struct CustomDockMenuAction: Identifiable {
    let id = UUID()
    let title: String
    var destructive = false
    let run: () -> Void
}
