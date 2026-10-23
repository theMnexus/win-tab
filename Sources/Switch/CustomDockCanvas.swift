import AppKit
import Combine
import SwiftUI

/// win-tab's Dock drawn with AppKit views. Each icon or widget is a SwiftUI view built once;
/// following the pointer only moves and scales those views (frame against a fixed bounds), so a
/// hover frame costs a few frame assignments instead of a SwiftUI graph update of the whole Dock.
/// Layout maths is `CustomDockLayout`, shared with the controller.
@MainActor
final class CustomDockCanvas: NSView {
    struct Callbacks {
        var onHover: (Int?) -> Void
        var onClick: (Int) -> Void
        var onDragChanged: () -> Void
        var onDragEnded: () -> Void
        var canMove: (Int) -> Bool
        var onDrop: (Int, CustomDockDrop) -> Void
        var menuAt: (Int) -> [CustomDockMenuAction]
    }

    /// One Dock item: `container.bounds` is the item at its largest drawn size, `container.frame`
    /// is what's shown, so AppKit scales the SwiftUI content without re-rendering it.
    private final class Slot {
        let container = NSView()
        let host: NSHostingView<DockFace>
        let dot = NSView()
        var item: CustomDockItem
        var big: CGSize

        init(face: DockFace) {
            item = face.item
            big = face.size
            host = NSHostingView(rootView: face)
            // Fixed-size content: no constraints or intrinsic size, and moving or scaling the
            // container must not lay the SwiftUI content out again.
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = []
            host.frame = CGRect(origin: .zero, size: face.size)
            container.wantsLayer = true
            container.autoresizesSubviews = false
            container.addSubview(host)
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 1.5
            dot.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.75).cgColor
        }
    }

    private enum DragMode: Equatable { case dock, item(Int) }
    private static let dragThreshold: CGFloat = 6
    private static let widgetRise: CGFloat = 4

    private let model: CustomDockModel
    private let callbacks: Callbacks
    private var prefs: SwitchPreferences { .shared }
    private var cancellables: Set<AnyCancellable> = []
    private var layout: CustomDockLayout
    private var slots: [Slot] = []
    private var bar = NSView()
    /// Settings → Dock → Style: a shadow under the bar and a tint and border over it.
    private let barShadow = NSView()
    private let barOverlay = NSView()
    /// Fills the edge gap under the bar. Fully clear pixels let the pointer through to the app
    /// below, so it's all but invisible instead; that way the edge reaches the Dock.
    private let edgeCatcher = NSView()
    private var barKey = ""
    /// The screen edge this Dock sits on (each display can have its own).
    var edge: ScreenEdge = .bottom {
        didSet { if edge != oldValue { alignBounds(); rebuild() } }
    }
    /// Empty strip between the Dock and the screen edge. It's inside the window so a pointer
    /// pushed against the edge still reaches the Dock (like Apple's); layout coordinates skip it.
    var edgeGap: CGFloat = 0 {
        didSet { if edgeGap != oldValue { alignBounds() } }
    }
    private let grip = DockGripView()
    private let marker = NSView()
    private let ring = NSView()

    private var pointer: CGPoint?
    private var reported: Int??
    private var mouseDown: (point: CGPoint, index: Int?)?
    private var drag: DragMode?
    /// An icon (or the Dock) is being dragged: auto-hide must wait, or the Dock stops taking
    /// the mouse mid-drag and the drop never arrives.
    var isDragging: Bool { drag != nil || mouseDown != nil }
    private var dragPoint: CGPoint = .zero
    private var bounceID: String?
    private var cursorPushed = false
    private var optionHeld = false
    /// ⌥ was down when the drag started: the whole Dock moves, whatever was grabbed.
    private var optionDrag = false
    /// Removed in `deinit`: a canvas goes away when a display does, its monitors used to stay.
    nonisolated(unsafe) private var flagMonitors: [Any] = []

    deinit { flagMonitors.forEach(NSEvent.removeMonitor) }

    init(model: CustomDockModel, callbacks: Callbacks) {
        self.model = model
        self.callbacks = callbacks
        layout = CustomDockLayout.make(prefs: .shared, items: model.items)
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        autoresizesSubviews = false
        // Files dragged from Finder onto the Trash item.
        registerForDraggedTypes([.fileURL])
        addSubview(grip)
        addSubview(barOverlay, positioned: .below, relativeTo: grip)
        addSubview(bar, positioned: .below, relativeTo: barOverlay)
        addSubview(barShadow, positioned: .below, relativeTo: bar)
        addSubview(edgeCatcher, positioned: .below, relativeTo: barShadow)
        edgeCatcher.wantsLayer = true
        edgeCatcher.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        barOverlay.wantsLayer = true
        barShadow.wantsLayer = true
        barShadow.layer?.shadowColor = NSColor.black.cgColor
        barShadow.layer?.shadowOffset = CGSize(width: 0, height: -3)
        barShadow.layer?.shadowRadius = 10
        for v in [marker, ring] {
            v.wantsLayer = true
            v.isHidden = true
        }
        marker.layer?.cornerRadius = 1.5
        ring.layer?.borderWidth = 2.5
        addSubview(marker)
        addSubview(ring)
        watchOption()
        model.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        SwitchPreferences.shared.objectWillChange
            .merge(with: StylePreferences.shared.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &cancellables)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        alignBounds()
    }

    /// Top and left gaps come before the layout's origin; bottom and right ones after its end.
    private func alignBounds() {
        let origin: CGPoint
        switch edge {
        case .top: origin = CGPoint(x: 0, y: -edgeGap)
        case .left: origin = CGPoint(x: -edgeGap, y: 0)
        case .bottom, .right: origin = .zero
        }
        if bounds.origin != origin { setBoundsOrigin(origin) }
    }

    /// "Hold ⌥" grip mode: the grip shows and any drag moves the Dock while Option is down.
    private func watchOption() {
        let handler = { [weak self] (event: NSEvent) in
            guard let self else { return }
            let held = event.modifierFlags.contains(.option)
            guard held != self.optionHeld else { return }
            self.optionHeld = held
            if self.prefs.customDockGripMode == .option {
                self.updateCursor(self.pointer)
                self.render(animation: .crossing)
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { e in MainActor.assumeIsolated { handler(e) } }) {
            flagMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in handler(e); return e }) {
            flagMonitors.append(m)
        }
    }

    /// Whether the grip shows now, per Settings → Dock → Grip.
    private var gripOn: Bool {
        guard layout.metrics.handle > 0 else { return false }
        if drag == .dock { return true }
        switch prefs.customDockGripMode {
        case .always: return true
        case .never: return false
        case .option: return optionHeld && pointer != nil
        case .edge:
            // Only near the Dock's start, not anywhere on it.
            guard let p = pointer, layout.count > 0 else { return false }
            return layout.alongComponent(p) < layout.rests[0] - layout.lengths[0] / 2 + layout.spacing
        }
    }

    // MARK: - Building

    /// The bar behind the items, in the chosen style and corner radius.
    private static func makeBar(style: SwitchPreferences.DockBarStyle, radius: CGFloat) -> NSView {
        if style == .glass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            return glass
        }
        let v: NSView
        switch style {
        case .glass, .blur:
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            v = blur
        case .dark, .clear:
            v = NSView()
        }
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = style == .dark ? NSColor.black.withAlphaComponent(0.72).cgColor : nil
        v.layer?.borderWidth = style == .clear ? 1 : 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(style == .clear ? 0.18 : 0.12).cgColor
        return v
    }

    private func updateBar() {
        let look = StylePreferences.shared
        updateBarDecor(look)
        let key = "\(prefs.customDockBarStyle.rawValue)|\(prefs.customDockCornerRadius)|\(look.dockBorder.rawValue)"
        guard key != barKey else { return }
        barKey = key
        let fresh = Self.makeBar(style: prefs.customDockBarStyle, radius: CGFloat(prefs.customDockCornerRadius))
        // A chosen border replaces the bar's own hairline.
        if look.dockBorder != .standard { fresh.layer?.borderWidth = 0 }
        fresh.frame = bar.frame
        bar.removeFromSuperview()
        addSubview(fresh, positioned: .below, relativeTo: barOverlay)
        bar = fresh
    }

    private func updateBarDecor(_ look: StylePreferences) {
        let radius = CGFloat(prefs.customDockCornerRadius)
        // Liquid Glass takes the tint into the glass; other bars get a layer over them.
        var glassTinted = false
        if #available(macOS 26.0, *), let glass = bar as? NSGlassEffectView {
            glass.tintColor = look.dockTint.isVisible ? NSColor(look.dockTint) : nil
            glass.style = look.glass == .clear ? .clear : .regular
            glassTinted = true
        }
        if let o = barOverlay.layer {
            o.cornerRadius = radius
            o.cornerCurve = .continuous
            o.backgroundColor = glassTinted ? nil : NSColor(look.dockTint).cgColor
            let border = look.resolve(look.dockBorder, custom: look.dockBorderColor)
            o.borderWidth = border == nil ? 0 : CGFloat(look.dockBorderWidth)
            o.borderColor = border.map { NSColor($0).cgColor }
        }
        barShadow.layer?.shadowOpacity = Float(look.dockShadow)
        let dot = look.resolve(look.dockIndicator, custom: look.dockIndicatorColor).map { NSColor($0) }
            ?? NSColor.labelColor.withAlphaComponent(0.75)
        for slot in slots { slot.dot.layer?.backgroundColor = dot.cgColor }
    }

    /// Items and settings changed: reuse views by id, rebuild only what's new or different.
    private func rebuild() {
        layout = CustomDockLayout.make(prefs: prefs, items: model.items, edge: edge)
        updateBar()
        marker.layer?.backgroundColor = NSColor(prefs.accent.color).cgColor
        ring.layer?.borderColor = NSColor(prefs.accent.color).cgColor
        var reuse: [String: Slot] = [:]
        for slot in slots { reuse[slot.item.id] = slot }
        var next: [Slot] = []
        for (i, item) in model.items.enumerated() {
            let face = makeFace(item, index: i)
            if let slot = reuse.removeValue(forKey: item.id) {
                if slot.item != item || slot.big != face.size {
                    slot.host.rootView = face
                    slot.host.frame = CGRect(origin: .zero, size: face.size)
                }
                slot.item = item
                slot.big = face.size
                next.append(slot)
            } else {
                let slot = Slot(face: face)
                addSubview(slot.container, positioned: .below, relativeTo: marker)
                addSubview(slot.dot, positioned: .below, relativeTo: marker)
                next.append(slot)
            }
        }
        for gone in reuse.values {
            gone.container.removeFromSuperview()
            gone.dot.removeFromSuperview()
        }
        slots = next
        updateBarDecor(StylePreferences.shared)
        render(animation: nil)
    }

    private func renderScale(_ item: CustomDockItem) -> CGFloat {
        guard item.magnifies else { return 1 }
        let effect = prefs.customDockHoverEffect
        return max(layout.maxScale, effect == .lift || effect == .glow ? layout.metrics.hoverZoom : 1)
    }

    private func makeFace(_ item: CustomDockItem, index i: Int) -> DockFace {
        let rest = layout.itemSize(i), r = renderScale(item)
        let isWidget: Bool = { switch item.content { case .widget, .stack: return true; default: return false } }()
        let id = item.id
        return DockFace(item: item, size: CGSize(width: rest.width * r, height: rest.height * r), side: layout.iconSize * r,
                        vertical: layout.edge.isVertical, showBadges: prefs.customDockShowBadges,
                        onTap: isWidget ? { [weak self] in self?.clickItem(id: id) } : nil)
    }

    // MARK: - Rendering

    private enum Motion { case crossing, moving }

    /// Places everything for the current pointer. `animation` nil = straight to the new frames.
    private func render(animation: Motion?) {
        guard slots.count == layout.count else { return }
        let along = drag != nil ? nil : pointer.map(layout.alongComponent)
        let frames = glides && glideAlong != nil
            ? layout.frames(pointerAlong: glideAlong?.value, amount: glideAmount.value)
            : layout.frames(pointerAlong: along)
        let hovered = along.flatMap(layout.index(atAlong:))
        let targets = slots.indices.map { target(for: $0, frame: frames.items[$0], hovered: hovered == $0) }
        // The grip takes no room until the pointer is on the Dock; then the bar grows at its start to show it.
        let gripOn = self.gripOn
        let barRect = layout.barRect(start: frames.barStart - (gripOn ? layout.metrics.handle : 0), end: frames.barEnd)
        let handle = layout.handleRect(barStart: frames.barStart)
        grip.isHidden = layout.metrics.handle == 0
        grip.shown = gripOn
        grip.vertical = layout.edge.isVertical
        let timing = animation.flatMap(timing(for:))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = timing?.duration ?? 0
            if let curve = timing?.curve { ctx.timingFunction = curve }
            let animated = timing != nil
            for (i, slot) in slots.enumerated() {
                set(slot.container, frame: targets[i].frame, bounds: slot.big, animated: animated)
                set(slot.dot, frame: targets[i].dot, animated: animated)
                slot.dot.isHidden = !slot.item.isRunning || prefs.customDockIndicator == .none
            }
            set(bar, frame: barRect, animated: animated)
            set(barOverlay, frame: barRect, animated: animated)
            set(barShadow, frame: barRect, animated: animated)
            set(grip, frame: handle, animated: animated)
        }
        placeShadow(barRect)
        edgeCatcher.frame = edgeStrip(barRect)
    }

    /// From `r`'s screen-side end to the window edge, across `r`'s span along the Dock.
    private func edgeStrip(_ r: CGRect) -> CGRect {
        switch edge {
        case .bottom: return CGRect(x: r.minX, y: r.maxY, width: r.width, height: max(bounds.maxY - r.maxY, 0))
        case .top: return CGRect(x: r.minX, y: bounds.minY, width: r.width, height: max(r.minY - bounds.minY, 0))
        case .left: return CGRect(x: bounds.minX, y: r.minY, width: max(r.minX - bounds.minX, 0), height: r.height)
        case .right: return CGRect(x: r.maxX, y: r.minY, width: max(bounds.maxX - r.maxX, 0), height: r.height)
        }
    }

    private func placeShadow(_ rect: CGRect) {
        guard barShadow.layer?.shadowOpacity ?? 0 > 0 else { return }
        let r = min(CGFloat(prefs.customDockCornerRadius), rect.height / 2, rect.width / 2)
        barShadow.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private func set(_ view: NSView, frame: CGRect, bounds: CGSize? = nil, animated: Bool) {
        if animated {
            view.animator().frame = frame
        } else if view.frame != frame {
            view.layer?.removeAllAnimations()
            view.frame = frame
        }
        if let bounds, view.bounds.size != bounds { view.bounds = CGRect(origin: .zero, size: bounds) }
    }

    /// Motion per the "Hover motion" setting: Instant never animates; Smooth tracks the pointer
    /// exactly and eases only in and out; Spring and Bouncy overshoot.
    private func timing(for motion: Motion) -> (duration: Double, curve: CAMediaTimingFunction)? {
        switch (prefs.customDockHoverMotion, motion) {
        case (.instant, _): return nil
        case (.smooth, .moving): return (0.05, CAMediaTimingFunction(name: .linear))
        case (.smooth, .crossing): return (0.26, CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        case (.spring, .crossing): return (0.3, CAMediaTimingFunction(controlPoints: 0.25, 1.2, 0.4, 1))
        case (.spring, .moving): return (0.1, CAMediaTimingFunction(name: .easeOut))
        case (.bouncy, .crossing): return (0.4, CAMediaTimingFunction(controlPoints: 0.3, 1.5, 0.45, 1))
        case (.bouncy, .moving): return (0.1, CAMediaTimingFunction(controlPoints: 0.3, 1.3, 0.5, 1))
        }
    }

    /// Shown rect of an item and of its running dot, for its magnified frame and hover state.
    private func target(for i: Int, frame: CustomDockLayout.Frame, hovered: Bool) -> (frame: CGRect, dot: CGRect) {
        let item = slots[i].item
        let rest = layout.itemSize(i)
        var scale = frame.scale
        var center = layout.point(along: frame.center, across: layout.across)
        var rise: CGFloat = 0
        if item.magnifies && hovered {
            switch prefs.customDockHoverEffect {
            case .lift:
                scale = layout.metrics.hoverZoom
                rise = layout.iconSize * CustomDockLayout.liftRise
            case .glow: scale = layout.metrics.hoverZoom
            case .magnify, .none: break
            }
        } else if hovered && !item.magnifies && item.units(vertical: layout.edge.isVertical) >= 1 {
            rise = Self.widgetRise
        }
        if bounceID == item.id { rise += layout.iconSize * CustomDockLayout.liftRise }
        if hopID == item.id { rise += layout.iconSize * CustomDockLayout.attentionRise }
        if case .item(let d) = drag, d == i {
            center = dragPoint
            scale = 1.1
        }
        let shown = CGSize(width: rest.width * scale, height: rest.height * scale)
        var origin = anchored(center: center, rest: rest, shown: shown)
        let away = layout.awayFromEdge
        origin.x += away.x * rise
        origin.y += away.y * rise
        let d = layout.point(along: frame.center, across: layout.indicatorAcross)
        // Dot, or a short line along the Dock.
        let long: CGFloat = prefs.customDockIndicator == .line ? 12 : 4
        let dot = layout.edge.isVertical ? CGSize(width: 3, height: long) : CGSize(width: long, height: 3)
        let size = prefs.customDockIndicator == .line ? dot : CGSize(width: 4, height: 4)
        return (CGRect(origin: origin, size: shown), CGRect(x: d.x - size.width / 2, y: d.y - size.height / 2, width: size.width, height: size.height))
    }

    /// Keeps the edge nearest the screen in place while an item grows.
    private func anchored(center: CGPoint, rest: CGSize, shown: CGSize) -> CGPoint {
        switch layout.edge {
        case .bottom: return CGPoint(x: center.x - shown.width / 2, y: center.y + rest.height / 2 - shown.height)
        case .top: return CGPoint(x: center.x - shown.width / 2, y: center.y - rest.height / 2)
        case .left: return CGPoint(x: center.x - rest.width / 2, y: center.y - shown.height / 2)
        case .right: return CGPoint(x: center.x + rest.width / 2 - shown.width, y: center.y - shown.height / 2)
        }
    }

    // MARK: - Glide

    /// A damped spring stepped by hand, once per screen refresh.
    private struct Spring {
        var value: CGFloat = 0
        var velocity: CGFloat = 0

        /// `response` = seconds to settle-ish, `damping` 1 = no overshoot.
        mutating func step(to target: CGFloat, dt: CGFloat, response: CGFloat, damping: CGFloat) {
            let k = pow(2 * .pi / response, 2), c = 4 * .pi * damping / response
            // Substeps keep the stiff Smooth spring stable at 60 Hz.
            let n = max(1, Int(ceil(dt * 480)))
            let h = dt / CGFloat(n)
            for _ in 0..<n {
                velocity += (k * (target - value) - c * velocity) * h
                value += velocity * h
            }
        }

        func settled(at target: CGFloat, within e: CGFloat) -> Bool { abs(target - value) < e && abs(velocity) < e * 10 }
    }

    private var glideLink: CADisplayLink?
    /// Shown pointer along the Dock; nil = magnification fully at rest.
    private var glideAlong: Spring?
    /// 0 = icons at rest, 1 = fully magnified.
    private var glideAmount = Spring()
    private var glideTarget: CGFloat = 0
    private var glideLast: CFTimeInterval = 0

    /// Magnify follows the pointer through springs stepped every display frame. A short animation
    /// per mouse event restarts at uneven times (events don't land on frames), so the zoom stutters.
    private var glides: Bool {
        prefs.customDockHoverEffect == .magnify && layout.maxScale > 1 && prefs.customDockHoverMotion != .instant && drag == nil
    }

    private var glideFeel: (along: CGFloat, alongDamping: CGFloat, amount: CGFloat, amountDamping: CGFloat) {
        switch prefs.customDockHoverMotion {
        case .instant, .smooth: return (0.07, 1, 0.22, 1)
        case .spring: return (0.1, 0.8, 0.3, 0.75)
        case .bouncy: return (0.13, 0.6, 0.38, 0.55)
        }
    }

    private func startGlide(_ p: CGPoint?) {
        if let p { glideTarget = layout.alongComponent(p) }
        if glideAlong == nil { glideAlong = Spring(value: glideTarget) }
        guard glideLink == nil else { return }
        glideLast = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(glideTick(_:)))
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    private func stopGlide() {
        glideLink?.invalidate()
        glideLink = nil
    }

    @objc private func glideTick(_ link: CADisplayLink) {
        let dt = CGFloat(min(max(link.timestamp - glideLast, 0), 1.0 / 30))
        glideLast = link.timestamp
        guard glides, var along = glideAlong else {
            stopGlide()
            glideAlong = nil
            glideAmount = Spring()
            render(animation: nil)
            return
        }
        let feel = glideFeel, goal: CGFloat = pointer == nil ? 0 : 1
        along.step(to: glideTarget, dt: dt, response: feel.along, damping: feel.alongDamping)
        glideAmount.step(to: goal, dt: dt, response: feel.amount, damping: feel.amountDamping)
        glideAlong = along
        let done = along.settled(at: glideTarget, within: 0.05) && glideAmount.settled(at: goal, within: 0.002)
        if done {
            stopGlide()
            glideAmount = Spring(value: goal)
            if pointer == nil { glideAlong = nil }
        }
        render(animation: nil)
    }

    // MARK: - Hiding

    /// Slides and/or fades the Dock out of sight or back. Only layers move, so the render server
    /// animates it; moving the window instead runs on the main thread every frame and stutters.
    /// `duration` nil = no animation.
    func conceal(_ concealed: Bool, slide: Bool, fade: Bool, duration: Double?) {
        guard let layer else { return }
        let transform = concealed && slide ? concealTransform(layer) : CATransform3DIdentity
        let opacity: Float = concealed && fade ? 0 : 1
        let now = layer.presentation() ?? layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let duration, duration > 0 {
            let move: CABasicAnimation
            if concealed {
                move = CABasicAnimation(keyPath: "sublayerTransform")
                move.duration = duration
                move.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            } else {
                // A light spring like the notch's: arrives fast and settles with a small overshoot.
                let spring = CASpringAnimation(keyPath: "sublayerTransform")
                spring.stiffness = pow(2 * .pi / duration, 2)
                spring.damping = 4 * .pi * 0.78 / duration
                spring.duration = spring.settlingDuration
                move = spring
            }
            move.fromValue = NSValue(caTransform3D: now.sublayerTransform)
            move.toValue = NSValue(caTransform3D: transform)
            layer.add(move, forKey: "conceal.move")
            let fading = CABasicAnimation(keyPath: "opacity")
            fading.fromValue = now.opacity
            fading.toValue = opacity
            fading.duration = concealed ? duration * 0.7 : duration * 0.6
            fading.timingFunction = CAMediaTimingFunction(name: concealed ? .easeIn : .easeOut)
            layer.add(fading, forKey: "conceal.fade")
        }
        layer.sublayerTransform = transform
        layer.opacity = opacity
        CATransaction.commit()
    }

    /// Moves the bar just past the window's screen-side edge (the window clips it there).
    private func concealTransform(_ layer: CALayer) -> CATransform3D {
        let b = bar.frame, pad: CGFloat = 4
        // View coordinates are flipped (y down); the layer's may not be.
        let down: CGFloat = layer.isGeometryFlipped ? 1 : -1
        switch edge {
        case .bottom: return CATransform3DMakeTranslation(0, down * (bounds.maxY - b.minY + pad), 0)
        case .top: return CATransform3DMakeTranslation(0, -down * (b.maxY - bounds.minY + pad), 0)
        case .left: return CATransform3DMakeTranslation(-(b.maxX - bounds.minX + pad), 0, 0)
        case .right: return CATransform3DMakeTranslation(bounds.maxX - b.minX + pad, 0, 0)
        }
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    #if DEBUG
    /// Drags item `from` to `along` (a position along the Dock) through the real mouse handlers,
    /// with events made inside the app (the harness; no system input).
    func debugDrag(from: Int, toAlong along: CGFloat) {
        guard let window, from < layout.count else { return }
        let start = layout.point(along: layout.rests[from], across: layout.across)
        let end = layout.point(along: along, across: layout.across)
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = event(.leftMouseDown, start) { mouseDown(with: e) }
        for step in 1...8 {
            let t = CGFloat(step) / 8
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let e = event(.leftMouseDragged, p) { mouseDragged(with: e) }
        }
        if let e = event(.leftMouseUp, end) { mouseUp(with: e) }
    }

    /// Sweeps a pointer across the Dock through the real hover handler; per-step time in ms.
    func debugHoverSweep() -> (avg: Double, max: Double) {
        guard layout.count > 0 else { return (0, 0) }
        let a0 = layout.rests[0] - layout.lengths[0], a1 = layout.rests[layout.count - 1] + layout.lengths[layout.count - 1]
        var times: [Double] = []
        for step in 0...120 {
            let p = layout.point(along: a0 + (a1 - a0) * CGFloat(step) / 120, across: layout.across)
            let t = CACurrentMediaTime()
            hover(p)
            CATransaction.flush()
            times.append((CACurrentMediaTime() - t) * 1000)
        }
        hover(nil)
        return (times.reduce(0, +) / Double(times.count), times.max() ?? 0)
    }

    /// Positions along the Dock just before the first item and just after the last.
    var debugEnds: (front: CGFloat, end: CGFloat) {
        (layout.rests[0] - layout.lengths[0] / 2 - layout.spacing / 2, layout.rests[layout.count - 1] + layout.lengths[layout.count - 1] / 2 + layout.spacing / 2)
    }
    var debugCount: Int { layout.count }
    #endif

    // MARK: - Files dropped on the Trash

    private func trashUnder(_ sender: NSDraggingInfo) -> Int? {
        guard let t = trashIndex else { return nil }
        let p = layout.alongComponent(convert(sender.draggingLocation, from: nil))
        return abs(p - layout.rests[t]) <= layout.lengths[t] / 2 + layout.spacing / 2 ? t : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let over = trashUnder(sender) != nil
        showFileHint(over)
        return over ? .delete : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { showFileHint(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showFileHint(false)
        guard trashUnder(sender) != nil,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        TrashBin.recycle(urls)
        return true
    }

    private func showFileHint(_ on: Bool) {
        guard let t = trashIndex else { return }
        ring.frame = layout.itemRect(t).insetBy(dx: -4, dy: -4)
        ring.layer?.cornerRadius = layout.iconSize * 0.26
        ring.layer?.borderColor = NSColor.systemRed.cgColor
        ring.isHidden = !on
    }

    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) { hover(local(event)) }
    override func mouseEntered(with event: NSEvent) { hover(local(event)) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    private func hover(_ p: CGPoint?) {
        let zone = layout.hoverRect.union(edgeStrip(layout.hoverRect))
        let inside = p.map(zone.contains) ?? false
        let next = inside ? p : nil
        let wasGrip = gripOn, wasNil = pointer == nil
        pointer = next
        let crossing = wasNil != (next == nil) || wasGrip != gripOn
        updateCursor(next)
        report(next.flatMap { layout.index(atAlong: layout.alongComponent($0)) })
        if glides, next != nil || glideAlong != nil {
            startGlide(next)
            return
        }
        render(animation: crossing ? .crossing : .moving)
    }

    private func updateCursor(_ p: CGPoint?) {
        let onGrip = (optionHeld && prefs.customDockGripMode == .option && p != nil)
            || (p.map { gripOn && grip.frame.insetBy(dx: -3, dy: -3).contains($0) } ?? false)
        grip.hovering = onGrip
        if onGrip && !cursorPushed { NSCursor.openHand.push(); cursorPushed = true }
        if !onGrip && cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    /// The controller hears about changes of hovered item only, not every pointer move.
    private func report(_ index: Int?) {
        guard reported != .some(index) else { return }
        reported = .some(index)
        callbacks.onHover(index)
    }

    // MARK: - Clicks and drags

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bar.frame.contains(p) || edgeCatcher.frame.contains(p) || slots.contains(where: { $0.container.frame.contains(p) }) else { return nil }
        // Widgets keep their own buttons; everything else (and every right click) is ours.
        let type = NSApp.currentEvent?.type
        if type != .rightMouseDown, type != .rightMouseUp, let hit = super.hitTest(point),
           let slot = slots.first(where: { hit.isDescendant(of: $0.container) }) {
            switch slot.item.content {
            case .widget, .stack: return hit
            default: break
            }
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func index(at p: CGPoint) -> Int? { layout.index(atAlong: layout.alongComponent(p)) }

    override func mouseDown(with event: NSEvent) {
        let p = local(event)
        mouseDown = (p, index(at: p))
        optionDrag = prefs.customDockGripMode == .option && event.modifierFlags.contains(.option)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDown else { return }
        let p = local(event)
        if drag == nil {
            guard hypot(p.x - down.point.x, p.y - down.point.y) >= Self.dragThreshold else { return }
            report(nil)
            stopGlide()
            glideAlong = nil
            glideAmount = Spring()
            drag = optionDrag ? .dock : down.index.map { callbacks.canMove($0) ? .item($0) : .dock } ?? .dock
            (drag == .dock ? NSCursor.closedHand : NSCursor.closedHand).push()
        }
        dragPoint = p
        if drag == .dock {
            callbacks.onDragChanged()
        } else {
            showDropHint(dropTarget())
        }
        render(animation: nil)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDown = nil }
        guard let mode = drag else {
            if let i = mouseDown?.index, slots.indices.contains(i) { clickItem(id: slots[i].item.id) }
            return
        }
        let target = dropTarget()
        drag = nil
        groupCandidate = nil
        groupRefresh?.cancel()
        NSCursor.pop()
        showDropHint(nil)
        switch mode {
        case .item(let i): if let target { callbacks.onDrop(i, target) }
        case .dock: callbacks.onDragEnded()
        }
        hover(local(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let i = index(at: local(event)) else { return }
        let actions = callbacks.menuAt(i)
        guard !actions.isEmpty else { return }
        let menu = NSMenu()
        for action in actions {
            let item = NSMenuItem(title: action.title, action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
            item.target = MenuTarget.shared
            item.representedObject = MenuTarget.Box(action)
            if action.destructive {
                item.attributedTitle = NSAttributedString(string: action.title, attributes: [.foregroundColor: NSColor.systemRed])
            }
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func clickItem(id: String) {
        guard let i = slots.firstIndex(where: { $0.item.id == id }) else { return }
        if prefs.customDockClickBounce, slots[i].item.magnifies { bounce(id) }
        callbacks.onClick(i)
    }

    // MARK: - Attention

    /// Apps asking for attention hop, like in Apple's Dock, until they stop asking (or for about
    /// 15 s); an informational request lasts about a second, so one or two hops.
    private var attention: Set<String> = []
    private var hopID: String?
    private static let maxHops = 24
    private static let hopInterval: TimeInterval = 0.6
    private static let hopUp: TimeInterval = 0.22

    func setAttention(_ ids: Set<String>) {
        let started = ids.subtracting(attention)
        attention = ids
        started.forEach { hop($0, left: Self.maxHops) }
    }

    private func hop(_ id: String, left: Int) {
        // The first hop always runs: a one-second request may already be over.
        guard left > 0, attention.contains(id) || left == Self.maxHops else { return }
        hopID = id
        render(animation: .crossing)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hopUp) { [weak self] in
            guard let self, self.hopID == id else { return }
            self.hopID = nil
            self.render(animation: .crossing)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hopInterval) { [weak self] in self?.hop(id, left: left - 1) }
    }

    private func bounce(_ id: String) {
        bounceID = id
        render(animation: .crossing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.bounceID == id else { return }
            self.bounceID = nil
            self.render(animation: .crossing)
        }
    }

    // MARK: - Drop targets

    /// Held this long over an app, a dragged app makes a group; passing over it just moves.
    private static let groupHold: CFTimeInterval = 0.45
    private var groupCandidate: (index: Int, since: CFTimeInterval)?
    private var groupRefresh: DispatchWorkItem?

    private var trashIndex: Int? { slots.firstIndex { if case .trash = $0.item.content { return true }; return false } }

    private func dropTarget() -> CustomDockDrop? {
        guard case .item(let i) = drag, slots.indices.contains(i) else { return nil }
        let p = layout.alongComponent(dragPoint)
        // Onto the Trash: off the Dock (only saved items; a running app would just come back).
        if let t = trashIndex, abs(p - layout.rests[t]) <= layout.lengths[t] / 2 + layout.spacing / 2 {
            return slots[i].item.entryID != nil ? .remove : nil
        }
        if slots[i].item.content == .app {
            let onto = slots.indices.first { k in
                guard k != i else { return false }
                let groupable: Bool = { if case .group = slots[k].item.content { return true }; return slots[k].item.content == .app }()
                return groupable && abs(p - layout.rests[k]) < layout.lengths[k] * 0.28
            }
            if let k = onto {
                let now = CACurrentMediaTime()
                if groupCandidate?.index != k {
                    groupCandidate = (k, now)
                    scheduleGroupRefresh()
                } else if let since = groupCandidate?.since, now - since >= Self.groupHold {
                    return .group(k)
                }
            } else {
                groupCandidate = nil
            }
        }
        // Moving: never past the divider before the Trash, or onto the Trash's spot.
        let limit = trashIndex.map { $0 - 1 } ?? layout.count
        let at = min(layout.rests.filter { $0 < p }.count, limit)
        return at == i || at == i + 1 ? nil : .insert(at)
    }

    /// Shows the group ring once the hold is long enough, even if the pointer stopped moving.
    private func scheduleGroupRefresh() {
        groupRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.drag != nil else { return }
            self.showDropHint(self.dropTarget())
        }
        groupRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.groupHold + 0.02, execute: work)
    }

    private func showDropHint(_ target: CustomDockDrop?) {
        marker.isHidden = true
        ring.isHidden = true
        switch target {
        case .group(let k):
            ring.frame = layout.itemRect(k).insetBy(dx: -4, dy: -4)
            ring.layer?.cornerRadius = layout.iconSize * 0.26
            ring.layer?.borderColor = NSColor(prefs.accent.color).cgColor
            ring.isHidden = false
        case .remove:
            guard let t = trashIndex else { return }
            ring.frame = layout.itemRect(t).insetBy(dx: -4, dy: -4)
            ring.layer?.cornerRadius = layout.iconSize * 0.26
            ring.layer?.borderColor = NSColor.systemRed.cgColor
            ring.isHidden = false
        case .insert(let at):
            guard layout.count > 0 else { return }
            let along = at >= layout.count
                ? layout.rests[layout.count - 1] + layout.lengths[layout.count - 1] / 2 + layout.spacing / 2
                : layout.rests[at] - layout.lengths[at] / 2 - layout.spacing / 2
            let c = layout.point(along: along, across: layout.across), long = layout.iconSize * 0.9
            marker.frame = layout.edge.isVertical ? CGRect(x: c.x - long / 2, y: c.y - 1.5, width: long, height: 3)
                : CGRect(x: c.x - 1.5, y: c.y - long / 2, width: 3, height: long)
            marker.isHidden = false
        case nil:
            break
        }
    }
}

/// Runs a context-menu action (NSMenuItem needs an Objective-C target).
@MainActor
private final class MenuTarget: NSObject {
    final class Box: NSObject {
        let action: CustomDockMenuAction
        init(_ action: CustomDockMenuAction) { self.action = action }
    }
    static let shared = MenuTarget()
    @objc func run(_ sender: NSMenuItem) { (sender.representedObject as? Box)?.action.run() }
}

/// The drag grip: a short rounded bar across the Dock, like the bar left at the screen edge
/// while the Dock is hidden (white in Dark Mode, black in Light Mode); bolder under the pointer.
@MainActor
private final class DockGripView: NSView {
    var shown = false { didSet { if shown != oldValue { fade() } } }
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    var vertical = false { didSet { if vertical != oldValue { needsDisplay = true } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    private func fade() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = shown ? 1 : 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = dark ? NSColor.white : NSColor.black
        base.withAlphaComponent(hovering ? 0.95 : 0.55).setFill()
        let thickness: CGFloat = hovering ? 3.5 : 3
        // Runs across the Dock: upright on a horizontal Dock, flat on a vertical one.
        let long = (vertical ? bounds.width : bounds.height) * (hovering ? 0.62 : 0.5)
        let r = vertical
            ? CGRect(x: bounds.midX - long / 2, y: bounds.midY - thickness / 2, width: long, height: thickness)
            : CGRect(x: bounds.midX - thickness / 2, y: bounds.midY - long / 2, width: thickness, height: long)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.35 : 0.12)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSBezierPath(roundedRect: r, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }
}
