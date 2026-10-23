import AppKit
import SwiftUI

/// What the hover card shows: a header standing in for the Dock's own name label, plus the
/// app's windows when there are any.
@MainActor
final class DockPreviewModel: ObservableObject {
    struct Header: Equatable {
        var title = ""
        var subtitle = ""
        var badge: String?
        var icon: NSImage?
    }

    @Published var header = Header()
    @Published var windows: [WindowInfo] = []
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    var onPick: (WindowInfo) -> Void = { _ in }
}

/// Fixed geometry, so the panel size is known before SwiftUI lays out: measuring after a
/// content change returned the previous app's size, which made the card jump.
enum DockPreviewLayout {
    static let padding: CGFloat = 12
    static let headerHeight: CGFloat = 38
    static let sectionSpacing: CGFloat = 10
    static let tileSpacing: CGFloat = 10
    static let titleHeight: CGFloat = 20
    static let minWidth: CGFloat = 260
    static let maxColumns = 4
    static let cornerRadius: CGFloat = 14

    static func thumbSize(_ size: SwitchPreferences.DockThumbSize) -> CGSize {
        switch size {
        case .small: return CGSize(width: 150, height: 94)
        case .medium: return CGSize(width: 190, height: 118)
        case .large: return CGSize(width: 240, height: 150)
        }
    }

    static func columns(for count: Int) -> Int { min(max(count, 1), maxColumns) }

    /// Wide enough for the whole name, and wider than the Dock's own bubble for that name.
    static func minWidth(for header: DockPreviewModel.Header) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let text = (header.title as NSString).size(withAttributes: [.font: font]).width
        let badge: CGFloat = header.badge == nil ? 0 : 36
        return max(minWidth, ceil(text) + padding * 2 + 28 + 9 + badge + 8)
    }

    /// Tile size for `n` windows: when a narrow grid (one window) wouldn't fill the card's
    /// minimum width, tiles grow proportionally so both side margins match.
    static func tileSize(windowCount n: Int, thumb: CGSize, minWidth: CGFloat = minWidth) -> CGSize {
        let cols = CGFloat(columns(for: n))
        let fillWidth = (minWidth - padding * 2 - (cols - 1) * tileSpacing) / cols
        guard fillWidth > thumb.width else { return thumb }
        return CGSize(width: fillWidth, height: (thumb.height * fillWidth / thumb.width).rounded())
    }

    static func size(windowCount n: Int, thumb base: CGSize, minWidth: CGFloat = minWidth) -> CGSize {
        guard n > 0 else { return CGSize(width: minWidth, height: padding * 2 + headerHeight) }
        let thumb = tileSize(windowCount: n, thumb: base, minWidth: minWidth)
        let cols = columns(for: n)
        let rows = Int(ceil(Double(n) / Double(cols)))
        let gridW = CGFloat(cols) * thumb.width + CGFloat(cols - 1) * tileSpacing
        let tileH = thumb.height + titleHeight
        let gridH = CGFloat(rows) * tileH + CGFloat(rows - 1) * tileSpacing
        return CGSize(width: max(minWidth, gridW + padding * 2),
                      height: padding * 2 + headerHeight + sectionSpacing + gridH)
    }
}

/// Borderless, non-activating panel floated beside the Dock, above its label layer (the Dock
/// draws at level 20, this sits at pop-up-menu level), so it covers the Dock's own tooltip.
@MainActor
final class DockPreviewPanel: NSPanel {
    let model = DockPreviewModel()
    private static let gap: CGFloat = 8
    /// Apple's bubble starts right past the magnified icon, inside the 14 pt padding `reach`
    /// adds (measured on macOS 27, right-edge Dock at 16/62 pt), so the card reaches in that far.
    private static let labelOverlap: CGFloat = 17
    private static let fadeDuration: TimeInterval = 0.12
    /// Spring for sliding between icons: response (s) and damping fraction.
    private static let moveResponse: Double = 0.26
    private static let moveDamping: Double = 0.86
    private var hiding = false
    private lazy var host = NSHostingView(rootView: DockPreviewView(model: model))
    /// Where the card is on screen. While it slides the window also covers where it came from.
    private var cardFrame: CGRect = .zero
    private var slideGeneration = 0

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        host.wantsLayer = true
        let container = NSView()
        container.wantsLayer = true
        container.addSubview(host)
        contentView = container
    }

    override var canBecomeKey: Bool { false }

    /// Pointer over the panel, checked geometrically: a non-key panel's hover tracking
    /// misses exits when the pointer jumps away.
    var containsPointer: Bool { isVisible && !hiding && cardFrame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) }

    /// `anchor` is the Dock icon's frame in global top-left (AX) coordinates. `coverLabel`: the card
    /// stands in for Apple's name bubble, so it appears at once and sits where the bubble does.
    func show(header: DockPreviewModel.Header, windows: [WindowInfo], anchor: CGRect, dock: DockGeometry, coverLabel: Bool = false) {
        let thumb = DockPreviewLayout.thumbSize(SwitchPreferences.shared.dockThumbSize)
        let size = DockPreviewLayout.size(windowCount: windows.count, thumb: thumb, minWidth: DockPreviewLayout.minWidth(for: header))
        // The bubble hugs the magnified icons; the card overlaps that spot instead of leaving a gap.
        let clearance = coverLabel ? dock.reach - Self.labelOverlap : dock.reach + Self.gap
        let target = CGRect(origin: dock.cardOrigin(size: size, anchor: anchor, clearance: clearance), size: size)
        if model.header != header { model.header = header }
        if model.windows.map(\.id) != windows.map(\.id) { model.windows = windows }
        // Only this app's windows: thumbnails (up to 960 px each) piled up for every window ever hovered.
        let ids = Set(windows.map(\.id))
        if model.thumbnails.keys.contains(where: { !ids.contains($0) }) { model.thumbnails = model.thumbnails.filter { ids.contains($0.key) } }
        recapturedAt = recapturedAt.filter { ids.contains($0.key) }
        loadThumbnails(for: windows)

        let wasShown = isVisible && !hiding
        hiding = false
        if !wasShown {
            place(target)
            // A fade-in would let the bubble show through for its first frames.
            alphaValue = coverLabel ? 1 : 0
            orderFrontRegardless()
            if alphaValue < 1 { fade(to: 1) }
        } else if cardFrame != target {
            slide(to: target)
        }
    }

    /// The window is exactly the card.
    private func place(_ card: CGRect) {
        slideGeneration += 1
        host.layer?.removeAnimation(forKey: "slide")
        setFrame(card, display: true)
        host.frame = CGRect(origin: .zero, size: card.size)
        cardFrame = card
        hasShadow = true
        invalidateShadow()
    }

    /// Moves the card to another icon. Only its layer moves (the render server animates it);
    /// resizing the window every frame made SwiftUI lay the card out again each frame and stutter.
    private func slide(to target: CGRect) {
        // Where the card shows right now, mid-slide included.
        let t = host.layer?.presentation()?.transform ?? CATransform3DIdentity
        let shown = CGRect(x: frame.minX + host.frame.minX + t.m41, y: frame.minY + host.frame.minY + t.m42,
                           width: cardFrame.width, height: cardFrame.height)
        let span = shown.union(target)
        slideGeneration += 1
        let mine = slideGeneration
        // The window's shadow is drawn once for the whole window, so it can't follow the card.
        hasShadow = false
        setFrame(span, display: false)
        host.frame = CGRect(x: target.minX - span.minX, y: target.minY - span.minY, width: target.width, height: target.height)
        cardFrame = target
        guard let layer = host.layer else { return place(target) }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.stiffness = pow(2 * .pi / Self.moveResponse, 2)
        spring.damping = 4 * .pi * Self.moveDamping / Self.moveResponse
        spring.duration = spring.settlingDuration
        spring.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(shown.minX - target.minX, shown.minY - target.minY, 0))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.slideGeneration == mine, self.isVisible else { return }
                self.place(target)
            }
        }
        layer.add(spring, forKey: "slide")
        CATransaction.commit()
    }

    func hide() {
        guard isVisible, !hiding else { return }
        hiding = true
        fade(to: 0) { [weak self] in
            guard let self, self.hiding else { return }
            self.orderOut(nil)
            self.hiding = false
        }
    }

    private func fade(to alpha: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    /// Last forced capture per window: a thumbnail cached by the background prewarm can be a
    /// half-painted frame (a Chrome page mid-load or mid-Space-move), so every show recaptures,
    /// at most once per `recaptureInterval` per window.
    private var recapturedAt: [CGWindowID: Date] = [:]
    private static let recaptureInterval: TimeInterval = 2

    private func loadThumbnails(for windows: [WindowInfo]) {
        let now = Date()
        for w in windows {
            let cachedFirst = model.thumbnails[w.id] == nil
            let due = now.timeIntervalSince(recapturedAt[w.id] ?? .distantPast) >= Self.recaptureInterval
            guard cachedFirst || due else { continue }
            if due { recapturedAt[w.id] = now }
            Task { [weak self] in
                // Cached image straight away, then a fresh one replaces it.
                if cachedFirst, let img = await WindowSnapshotter.shared.snapshot(for: w.id) {
                    self?.model.thumbnails[w.id] = img
                }
                if due, let fresh = await WindowSnapshotter.shared.snapshot(for: w.id, force: true) {
                    self?.model.thumbnails[w.id] = fresh
                }
            }
        }
    }
}

enum ScreenEdge: String, CaseIterable, Identifiable {
    case left, bottom, right, top
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var isVertical: Bool { self == .left || self == .right }
}

/// Where a Dock sits and how far it reaches into the screen (magnified icons included).
struct DockGeometry {
    let edge: ScreenEdge
    let reach: CGFloat

    /// Apple's Dock, from its preferences.
    static var current: DockGeometry {
        let domain = DockAX.bundleID as CFString
        let raw = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String
        let edge = raw.flatMap(ScreenEdge.init(rawValue:)) ?? .bottom
        let tile = (CFPreferencesCopyAppValue("tilesize" as CFString, domain) as? NSNumber)?.doubleValue ?? 48
        let magnified = CFPreferencesCopyAppValue("magnification" as CFString, domain) as? Bool ?? false
        let large = (CFPreferencesCopyAppValue("largesize" as CFString, domain) as? NSNumber)?.doubleValue ?? 64
        // Icon plus the Dock's own padding around it.
        return DockGeometry(edge: edge, reach: CGFloat(magnified ? max(tile, large) : tile) + 14)
    }

    /// Where a card of `size` goes: beside the icon, `clearance` away from the screen edge the
    /// Dock sits on, kept on the icon's screen. `anchor` is global top-left (AX) coordinates.
    @MainActor
    func cardOrigin(size: CGSize, anchor: CGRect, clearance: CGFloat) -> CGPoint {
        // AX y runs down from the top of the primary display, the screen at the AppKit origin.
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let mainHeight = primary?.frame.height ?? 0
        let icon = CGRect(x: anchor.minX, y: mainHeight - anchor.maxY, width: anchor.width, height: anchor.height)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: icon.midX, y: icon.midY)) } ?? primary
        let frame = screen?.frame ?? .zero
        let bounds = frame.insetBy(dx: 8, dy: 8)
        var p: CGPoint
        switch edge {
        case .bottom: p = CGPoint(x: icon.midX - size.width / 2, y: frame.minY + clearance)
        case .left: p = CGPoint(x: frame.minX + clearance, y: icon.midY - size.height / 2)
        case .right: p = CGPoint(x: frame.maxX - clearance - size.width, y: icon.midY - size.height / 2)
        case .top: p = CGPoint(x: icon.midX - size.width / 2, y: frame.maxY - clearance - size.height)
        }
        p.x = min(max(p.x, bounds.minX), bounds.maxX - size.width)
        p.y = min(max(p.y, bounds.minY), bounds.maxY - size.height)
        return p
    }
}

struct DockPreviewView: View {
    @ObservedObject var model: DockPreviewModel
    @ObservedObject private var prefs = SwitchPreferences.shared
    @State private var hoveredID: CGWindowID?

    private var baseThumb: CGSize { DockPreviewLayout.thumbSize(prefs.dockThumbSize) }
    private var minWidth: CGFloat { DockPreviewLayout.minWidth(for: model.header) }
    private var thumb: CGSize { DockPreviewLayout.tileSize(windowCount: model.windows.count, thumb: baseThumb, minWidth: minWidth) }
    private var size: CGSize { DockPreviewLayout.size(windowCount: model.windows.count, thumb: baseThumb, minWidth: minWidth) }

    var body: some View {
        VStack(alignment: .leading, spacing: DockPreviewLayout.sectionSpacing) {
            header
            if !model.windows.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(thumb.width), spacing: DockPreviewLayout.tileSpacing),
                                         count: DockPreviewLayout.columns(for: model.windows.count)),
                          alignment: .leading, spacing: DockPreviewLayout.tileSpacing) {
                    ForEach(model.windows) { tile($0) }
                }
            }
        }
        .padding(DockPreviewLayout.padding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            if prefs.backgroundBlur != .glass { Rectangle().fill(prefs.backgroundBlur.material) }
        }
        .flatTint(StylePreferences.shared.windowTint, glass: prefs.backgroundBlur == .glass)
        .liquidGlass(prefs.backgroundBlur == .glass, cornerRadius: DockPreviewLayout.cornerRadius, tint: StylePreferences.shared.windowTint)
        .clipShape(RoundedRectangle(cornerRadius: DockPreviewLayout.cornerRadius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 9) {
            if let icon = model.header.icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.header.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !model.header.subtitle.isEmpty {
                    Text(model.header.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let badge = model.header.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Color.red))
            }
        }
        .frame(height: DockPreviewLayout.headerHeight)
    }

    private func tile(_ window: WindowInfo) -> some View {
        let hovered = hoveredID == window.id
        return VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.black.opacity(0.2)
                if let img = model.thumbnails[window.id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(4)
                        .transition(.opacity)
                } else if let icon = model.header.icon {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40).opacity(0.5)
                }
            }
            .frame(width: thumb.width, height: thumb.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(hovered ? prefs.accent.color : Color.clear, lineWidth: 2)
            )
            .scaleEffect(hovered ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hovered)
            Text(window.title.isEmpty ? window.appName : window.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: thumb.width, height: DockPreviewLayout.titleHeight - 4, alignment: .leading)
        }
        .frame(height: thumb.height + DockPreviewLayout.titleHeight, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? window.id : (hoveredID == window.id ? nil : hoveredID) }
        .onTapGesture { model.onPick(window) }
    }
}
