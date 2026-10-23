import AppKit

/// The thin bar left at the screen edge while win-tab's Dock is hidden, like the iPhone's home
/// indicator: hovering or clicking it brings the Dock back.
@MainActor
final class DockRevealBar {

    private let panel: NSPanel
    private let view: RevealView
    /// Bumped by every show/hide, so a hide's late completion can't order out a bar shown since.
    private var generation = 0
    /// Where the pointer reveals the Dock, in screen coordinates; nil while the bar is down.
    private(set) var hitFrame: CGRect?

    init(onReveal: @escaping () -> Void) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.alphaValue = 0
        view = RevealView(onReveal: onReveal)
        panel.contentView = view
    }

    /// Shows the bar along `edge` of `screen`, centred on where the Dock sits (`dock`).
    func show(edge: ScreenEdge, dock: CGRect, screen: NSScreen, animated: Bool, duration: Double) {
        let style = SwitchPreferences.shared.customDockRevealBar
        let f = screen.frame
        let look = StylePreferences.shared
        let dockLength = edge.isVertical ? dock.height : dock.width
        let edgeLength = edge.isVertical ? f.height : f.width
        // Up to the screen's edge; past the Dock's own length it reaches beyond the Dock's ends.
        let long = min(max(dockLength * CGFloat(look.revealLength), 40), edgeLength)
        let i = CGFloat(look.revealGap)
        let depth = CGFloat(look.revealThickness) + CGFloat(look.revealHoverHeight)
        // Kept on screen when the Dock sits near a corner.
        let along = edge.isVertical ? min(max(dock.midY - long / 2, f.minY), f.maxY - long)
                                    : min(max(dock.midX - long / 2, f.minX), f.maxX - long)
        // Only the bar itself (and the few points between it and the edge) brings the Dock back.
        let frame: CGRect
        switch edge {
        case .bottom: frame = CGRect(x: along, y: f.minY, width: long, height: depth + i)
        case .top: frame = CGRect(x: along, y: f.maxY - depth - i, width: long, height: depth + i)
        case .left: frame = CGRect(x: f.minX, y: along, width: depth + i, height: long)
        case .right: frame = CGRect(x: f.maxX - depth - i, y: along, width: depth + i, height: long)
        }
        // No bar drawn: the same spot still brings the Dock back, just invisibly.
        guard style != .none else {
            hide(animated: false, duration: 0)
            hitFrame = frame
            return
        }
        hitFrame = frame
        view.configure(edge: edge, thickness: CGFloat(look.revealThickness), inset: i,
                       glass: style == .glass, color: color(style), idleOpacity: CGFloat(look.revealIdleOpacity))
        generation += 1
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        fade(to: 1, animated: animated, duration: duration)
    }

    func hide(animated: Bool, duration: Double) {
        hitFrame = nil
        generation += 1
        let mine = generation
        fade(to: 0, animated: animated, duration: duration) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.panel.orderOut(nil)
        }
    }

    private func color(_ style: SwitchPreferences.DockRevealBar) -> NSColor {
        switch style {
        case .white: return NSColor.white.withAlphaComponent(0.9)
        case .black: return NSColor.black.withAlphaComponent(0.75)
        case .custom: return NSColor(StylePreferences.shared.revealColor)
        case .auto, .glass, .none:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor.white.withAlphaComponent(0.9) : NSColor.black.withAlphaComponent(0.75)
        }
    }

    private func fade(to alpha: CGFloat, animated: Bool, duration: Double, completion: (() -> Void)? = nil) {
        guard animated else {
            panel.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
    }
}

/// The bar itself is a subview (solid layer or Liquid Glass) whose opacity rests at the idle level
/// and rises while the pointer is near; the view's own near-clear fill keeps the whole strip
/// hit-testable, since fully transparent pixels let the pointer through to the window below.
private final class RevealView: NSView {
    /// Liquid Glass needs some body to read as glass.
    private static let minGlassThickness: CGFloat = 6

    private var edge: ScreenEdge = .bottom
    private var barThickness: CGFloat = 5
    private var inset: CGFloat = 4
    private var idleOpacity: CGFloat = 1
    private var pill = NSView()
    private var pillIsGlass: Bool?
    private let onReveal: () -> Void
    private var hovering = false

    init(onReveal: @escaping () -> Void) {
        self.onReveal = onReveal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(edge: ScreenEdge, thickness: CGFloat, inset: CGFloat, glass: Bool, color: NSColor, idleOpacity: CGFloat) {
        self.edge = edge
        self.inset = inset
        self.idleOpacity = min(max(idleOpacity, 0.05), 1)
        barThickness = glass ? max(thickness, Self.minGlassThickness) : thickness
        if pillIsGlass != glass {
            pill.removeFromSuperview()
            pill = Self.makePill(glass: glass)
            addSubview(pill)
            pillIsGlass = glass
        }
        if !glass { pill.layer?.backgroundColor = color.cgColor }
        hovering = false
        pill.alphaValue = self.idleOpacity
        needsLayout = true
    }

    private static func makePill(glass: Bool) -> NSView {
        let v: NSView
        if glass, #available(macOS 26.0, *) {
            v = NSGlassEffectView()
        } else if glass {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            v = blur
        } else {
            v = NSView()
        }
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        v.layer?.cornerCurve = .continuous
        if glass {
            v.layer?.borderWidth = 0.5
            v.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        }
        v.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 2
            return s
        }()
        return v
    }

    override func layout() {
        super.layout()
        let t = barThickness
        let r: CGRect
        switch edge {
        case .bottom: r = CGRect(x: 0, y: inset, width: bounds.width, height: t)
        case .top: r = CGRect(x: 0, y: bounds.height - inset - t, width: bounds.width, height: t)
        case .left: r = CGRect(x: inset, y: 0, width: t, height: bounds.height)
        case .right: r = CGRect(x: bounds.width - inset - t, y: 0, width: t, height: bounds.height)
        }
        pill.frame = r
        if #available(macOS 26.0, *), let glass = pill as? NSGlassEffectView { glass.cornerRadius = t / 2 }
        pill.layer?.cornerRadius = t / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
        onReveal()
    }

    override func mouseExited(with event: NSEvent) { setHovering(false) }

    override func mouseDown(with event: NSEvent) { onReveal() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Layer-backed view: the animator drives the layer's opacity on the render server.
    private func setHovering(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.18 : 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pill.animator().alphaValue = on ? 1 : idleOpacity
        }
    }
}
