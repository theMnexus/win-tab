import AppKit
import Combine
import QuartzCore
import SwiftUI

/// The island drawn with Core Animation. Its outline is one path shared by shape layers (fill,
/// glow, border, shadow) and by the mask over the content; opening and closing is a spring on
/// that path, which the render server interpolates, so no frame of it runs app code. The
/// SwiftUI content is built once and only fades.
@MainActor
final class NotchIslandView: NSView {
    private let state: NotchState
    private let geometry: NotchGeometry
    private var prefs: SwitchPreferences { .shared }
    private var cancellables: Set<AnyCancellable> = []

    private let backdrop = NSView()
    private let shadowShape = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let glow = CAGradientLayer()
    private let glowMask = CAShapeLayer()
    private let border = CAShapeLayer()
    private let dropBorder = CAShapeLayer()
    private let clip = NSView()
    private let clipMask = CAShapeLayer()
    private let expandedHost: NSHostingView<NotchExpandedContent>
    private let collapsedHost: NSHostingView<NotchCollapsedContent>
    private let alertHost: NSHostingView<NotchAlertContent>
    /// Invisible (alpha 0) views still take clicks in AppKit, so the alert layer never does:
    /// it's only for looking at, and it lies over the open island's top row.
    private let alertClip = PassthroughView()
    private let alertMask = CAShapeLayer()
    private var shownAlert: UUID?
    /// Settings → Notch → Tabs → Below the island: the floating bar, outside the island's mask.
    private var tabBarHost: NSHostingView<NotchTabBar>?
    private var shownExpanded: Bool?
    /// What was last drawn; unchanged updates (a song's position ticking) do nothing.
    private var drawnKey = ""

    init(state: NotchState, geometry: NotchGeometry) {
        self.state = state
        self.geometry = geometry
        expandedHost = NSHostingView(rootView: NotchExpandedContent(state: state, geometry: geometry))
        collapsedHost = NSHostingView(rootView: NotchCollapsedContent(state: state, geometry: geometry))
        alertHost = NSHostingView(rootView: NotchAlertContent(state: state, geometry: geometry))
        super.init(frame: CGRect(origin: .zero, size: geometry.panelFrame.size))
        wantsLayer = true
        autoresizingMask = [.width, .height]
        buildLayers()
        buildContent()
        registerForDraggedTypes([.fileURL])
        observe()
        update(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Building

    private func buildLayers() {
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        addSubview(backdrop)
        guard let root = backdrop.layer else { return }
        shadowShape.fillColor = NSColor.black.cgColor
        shadowShape.shadowColor = NSColor.black.cgColor
        shadowShape.shadowRadius = 16
        shadowShape.shadowOffset = CGSize(width: 0, height: -6)
        shadowShape.shadowOpacity = 0
        fill.fillColor = NSColor.black.cgColor
        glow.startPoint = CGPoint(x: 0.5, y: 1)
        glow.endPoint = CGPoint(x: 1, y: 0)
        glow.frame = bounds
        glow.mask = glowMask
        glowMask.fillColor = NSColor.white.cgColor
        border.fillColor = nil
        border.lineWidth = 1
        dropBorder.fillColor = nil
        dropBorder.lineWidth = 2
        dropBorder.lineDashPattern = [6, 4]
        dropBorder.isHidden = true
        [shadowShape, fill, glow, border, dropBorder].forEach(root.addSublayer)
    }

    private func buildContent() {
        let canvas = bounds.size
        let collapsedWidth = geometry.collapsedSize(wing: NotchGeometry.maxWing).width - NotchGeometry.flare * 2
        collapsedHost.frame = CGRect(x: (canvas.width - collapsedWidth) / 2, y: canvas.height - geometry.notch.height,
                                     width: collapsedWidth, height: geometry.notch.height)
        addSubview(collapsedHost)
        clip.frame = bounds
        clip.wantsLayer = true
        clip.layer?.mask = clipMask
        clipMask.fillColor = NSColor.white.cgColor
        let expanded = geometry.expandedSize
        expandedHost.frame = CGRect(x: (canvas.width - expanded.width) / 2 + NotchGeometry.flare, y: canvas.height - expanded.height,
                                    width: expanded.width - NotchGeometry.flare * 2, height: expanded.height)
        clip.addSubview(expandedHost)
        addSubview(clip)
        // The alert's content is masked by the outline too, so it's uncovered as the island grows.
        alertClip.frame = bounds
        alertClip.wantsLayer = true
        alertClip.layer?.mask = alertMask
        alertMask.fillColor = NSColor.white.cgColor
        let alert = geometry.alertSize(.expanded)
        alertHost.frame = CGRect(x: (canvas.width - alert.width) / 2 + NotchGeometry.flare, y: canvas.height - alert.height,
                                 width: alert.width - NotchGeometry.flare * 2, height: alert.height)
        alertClip.addSubview(alertHost)
        alertClip.alphaValue = 0
        addSubview(alertClip)
        if geometry.tabsBelow {
            let bar = NSHostingView(rootView: NotchTabBar(state: state))
            bar.frame = CGRect(x: 0, y: canvas.height - expanded.height - NotchGeometry.tabBarGap - NotchGeometry.tabBarHeight,
                               width: canvas.width, height: NotchGeometry.tabBarHeight)
            bar.wantsLayer = true
            addSubview(bar)
            // Grow about the bar's centre.
            bar.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.layer?.position = CGPoint(x: bar.frame.midX, y: bar.frame.midY)
            bar.layer?.opacity = 0
            tabBarHost = bar
        }
    }

    private func observe() {
        let redraw = { [weak self] in DispatchQueue.main.async { self?.update(animated: true) } }
        state.onResize = { [weak self] in self?.update(animated: false) }
        state.$expanded.sink { _ in redraw() }.store(in: &cancellables)
        state.$peeking.sink { _ in redraw() }.store(in: &cancellables)
        state.$dragNear.sink { _ in redraw() }.store(in: &cancellables)
        state.$dropTargeted.sink { _ in redraw() }.store(in: &cancellables)
        state.$alert.sink { _ in redraw() }.store(in: &cancellables)
        state.$tab.sink { _ in redraw() }.store(in: &cancellables)
        // Dragging the Notifications tab's height: follow the pointer exactly, no spring.
        NotificationFeed.shared.$tabExtra.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update(animated: !(self?.state.resizing ?? false)) }
        }.store(in: &cancellables)
        NotchTabHeights.shared.$files.merge(with: NotchTabHeights.shared.$translate).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update(animated: !(self?.state.resizing ?? false)) }
        }.store(in: &cancellables)
        NowPlayingMonitor.shared.objectWillChange.sink { _ in redraw() }.store(in: &cancellables)
        NotchTimer.shared.objectWillChange.sink { _ in redraw() }.store(in: &cancellables)
        prefs.objectWillChange.sink { _ in redraw() }.store(in: &cancellables)
        StylePreferences.shared.objectWillChange.sink { _ in redraw() }.store(in: &cancellables)
    }

    // MARK: - Shape

    /// The outline for an island of `size`, in this view's (bottom-left) coordinates.
    private func islandPath(_ size: CGSize, radius: CGFloat) -> CGPath {
        let canvas = bounds.size
        let rect = CGRect(x: (canvas.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        var flip = CGAffineTransform(translationX: 0, y: canvas.height).scaledBy(x: 1, y: -1)
        let path = NotchShape(bottomRadius: radius).path(in: rect).cgPath
        return path.copy(using: &flip) ?? path
    }

    /// Spring settings per the Notch → Animation setting: Smooth never overshoots.
    private var spring: (stiffness: CGFloat, damping: CGFloat) {
        switch prefs.notchAnimation {
        case .island, .smooth: return (420, 41)
        case .snappy: return (760, 52)
        case .bouncy: return (300, 17)
        }
    }

    private func animate(_ layer: CALayer, _ key: String, to value: Any, animated: Bool, closing: Bool) {
        let from = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        layer.setValue(value, forKeyPath: key)
        guard animated else {
            layer.removeAnimation(forKey: key)
            return
        }
        let a = CASpringAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = value
        a.mass = 1
        // Closing never bounces: the island settles straight back into the notch.
        a.stiffness = closing ? 560 : spring.stiffness
        a.damping = closing ? 47 : spring.damping
        a.duration = a.settlingDuration
        a.speed = Float(prefs.notchAnimationSpeed)
        layer.add(a, forKey: key)
    }

    // MARK: - Update

    private struct IslandShape: Equatable { var size: CGSize; var radius: CGFloat }
    /// The shape last set as the model value, and the sampled flight of an Island transition
    /// (so an interrupted transition restarts from what's on screen, not from its end).
    private var shownShape = IslandShape(size: .zero, radius: 0)
    private var flight: (samples: [IslandShape], start: CFTimeInterval, duration: CFTimeInterval)?

    func update(animated: Bool) {
        let expanded = state.expanded
        let alert = expanded ? nil : state.alert
        let alertStyle = alert?.style ?? BatteryPreferences.shared.notchAlertStyle
        let size = expanded ? geometry.expandedSize(for: state.tab)
            : alert != nil ? geometry.alertSize(alertStyle)
            : geometry.collapsedSize(wing: NotchActivity.wing(geometry), peeking: state.peeking, dragNear: state.dragNear)
        let radius = expanded ? 28 : alert != nil && alertStyle == .expanded ? 22 : geometry.notch.height * 0.38
        let path = islandPath(size, radius: radius)
        let toggling = shownExpanded != nil && shownExpanded != expanded
        let closing = (shownExpanded == true && !expanded) || (shownAlert != nil && alert == nil)
        let tint = alert.map { NSColor($0.color) } ?? NowPlayingMonitor.shared.tint.map { NSColor($0) }
        let look = IslandLook(StylePreferences.shared, tint: tint, expanded: expanded)
        let key = "\(size)|\(radius)|\(expanded)|\(state.tab)|\(tint?.description ?? "-")|\(state.dropTargeted)|\(bounds.size)|\(look)|\(alert?.id.uuidString ?? "-")"
        guard key != drawnKey else { return }
        drawnKey = key
        let target = IslandShape(size: size, radius: radius)
        let island = animated && toggling && prefs.notchAnimation == .island

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if island {
            islandTransition(from: currentShape(), to: target, opening: expanded)
        } else {
            flight = nil
            for layer in [fill, glowMask, border, dropBorder, clipMask, alertMask, shadowShape] {
                animate(layer, "path", to: path, animated: animated, closing: closing)
            }
            animate(shadowShape, "shadowPath", to: path, animated: animated, closing: closing)
        }
        shownShape = target
        animate(shadowShape, "shadowOpacity", to: Float(expanded || alert != nil ? look.shadow : 0), animated: animated, closing: closing)
        animate(fill, "fillColor", to: look.fill.cgColor, animated: animated, closing: closing)
        glow.frame = bounds
        glow.colors = [NSColor.clear.cgColor, (tint ?? .clear).withAlphaComponent(look.glow).cgColor]
        glow.locations = [0.3, 1]
        animate(glow, "opacity", to: Float((expanded || alert != nil) && tint != nil ? 1 : 0), animated: animated, closing: closing)
        border.strokeColor = alert.map { NSColor($0.color).withAlphaComponent(0.35).cgColor } ?? look.border.cgColor
        border.lineWidth = look.borderWidth
        dropBorder.strokeColor = NSColor(prefs.accent.color).cgColor
        dropBorder.isHidden = !state.dropTargeted
        CATransaction.commit()

        revealContent(expanded: expanded, animated: animated && toggling)
        if toggling || !animated { revealTabBar(expanded, animated: animated) } else if expanded { liftTabBar(animated: animated) }
        revealAlert(alert != nil, animated: animated)
        shownExpanded = expanded
        shownAlert = alert?.id
    }

    /// How far the tab bar sits above its spot (made for the tallest tab), so it hugs a shorter island.
    private var tabBarLift: CGFloat { geometry.expandedSize.height - geometry.expandedSize(for: state.tab).height }
    private var liftedTo: CGFloat = 0

    /// Moves the bar's frame (not just its drawing: clicks follow the frame) to sit under the
    /// island at the current lift, keeping it scaled about its centre.
    private func placeTabBar() {
        guard let bar = tabBarHost else { return }
        let canvas = bounds.size
        let y = canvas.height - geometry.expandedSize.height - NotchGeometry.tabBarGap - NotchGeometry.tabBarHeight + liftedTo
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.frame.origin.y = y
        bar.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        bar.layer?.position = CGPoint(x: bar.frame.midX, y: bar.frame.midY)
        bar.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Follows the island when a tab changes its height.
    private func liftTabBar(animated: Bool) {
        guard let layer = tabBarHost?.layer, tabBarLift != liftedTo else { return }
        let from = liftedTo
        liftedTo = tabBarLift
        placeTabBar()
        guard animated else { return }
        // The frame is already there; slide the drawing in from where it was.
        let move = CASpringAnimation(keyPath: "transform.translation.y")
        move.fromValue = from - liftedTo
        move.toValue = 0
        move.stiffness = spring.stiffness
        move.damping = spring.damping
        move.duration = move.settlingDuration
        move.speed = Float(prefs.notchAnimationSpeed)
        layer.add(move, forKey: "lift")
    }

    /// The tab bar drops out from under the island just after it opens, and leaves ahead of it.
    private func revealTabBar(_ on: Bool, animated: Bool) {
        guard let layer = tabBarHost?.layer else { return }
        let speed = Double(max(prefs.notchAnimationSpeed, 0.1))
        liftedTo = tabBarLift
        placeTabBar()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = on ? 1 : 0
        CATransaction.commit()
        guard animated else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = on ? 0 : 1
        fade.toValue = on ? 1 : 0
        let group = CAAnimationGroup()
        if on {
            let drop = CASpringAnimation(keyPath: "transform.translation.y")
            drop.fromValue = 14
            drop.toValue = 0
            drop.stiffness = 380
            drop.damping = 26
            let grow = CASpringAnimation(keyPath: "transform.scale.x")
            grow.fromValue = 0.82
            grow.toValue = 1
            grow.stiffness = 380
            grow.damping = 26
            fade.duration = 0.22
            group.animations = [fade, drop, grow]
            group.duration = drop.settlingDuration
            group.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.12 / speed
            group.fillMode = .backwards
        } else {
            fade.duration = 0.12
            group.animations = [fade]
            group.duration = 0.12
        }
        group.speed = Float(speed)
        layer.add(group, forKey: "tabBar")
    }

    /// The alert's content fades in just behind the outline and out ahead of it; the song or
    /// status items step aside meanwhile.
    private func revealAlert(_ on: Bool, animated: Bool) {
        guard (shownAlert != nil) != on || !animated else { return }
        let showCollapsed = !on && !state.expanded
        guard animated else {
            alertClip.alphaValue = on ? 1 : 0
            if !state.expanded { collapsedHost.alphaValue = showCollapsed ? 1 : 0 }
            return
        }
        let speed = Double(max(prefs.notchAnimationSpeed, 0.1))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = (on ? 0.3 : 0.14) / speed
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            alertClip.animator().alphaValue = on ? 1 : 0
            if !state.expanded { collapsedHost.animator().alphaValue = showCollapsed ? 1 : 0 }
        }
    }

    private func currentShape() -> IslandShape {
        guard let f = flight, !f.samples.isEmpty else { return shownShape }
        let t = (CACurrentMediaTime() - f.start) / f.duration
        guard t < 1 else { return shownShape }
        return f.samples[min(f.samples.count - 1, max(0, Int(t * Double(f.samples.count - 1))))]
    }

    /// Progress (0→1, may overshoot) of a unit-mass spring after `t` seconds.
    private static func spring(_ t: Double, stiffness k: Double, damping c: Double) -> Double {
        guard t > 0 else { return 0 }
        let w0 = k.squareRoot(), zeta = c / (2 * w0)
        guard zeta < 1 else { return 1 - exp(-w0 * t) * (1 + w0 * t) }
        let wd = w0 * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t))
    }

    /// Opening: the island widens first and then drops down, settling with a small overshoot, like
    /// the iPhone's Dynamic Island. Closing: it lifts first, then narrows back into the notch.
    /// Two springs sampled into one keyframe path animation, so the render server plays it all.
    private func islandTransition(from a: IslandShape, to b: IslandShape, opening: Bool) {
        let lead = opening ? (k: 520.0, c: 30.0) : (k: 760.0, c: 55.0)
        let follow = opening ? (k: 340.0, c: 29.0) : (k: 560.0, c: 47.0)
        let followDelay = opening ? 0.06 : 0.035
        let duration = opening ? 0.66 : 0.42
        let rate = 120.0, steps = Int(duration * rate)
        var samples: [IslandShape] = []
        samples.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Double(i) / rate
            let pl = Self.spring(t, stiffness: lead.k, damping: lead.c)
            let pf = Self.spring(t - followDelay, stiffness: follow.k, damping: follow.c)
            let pw = CGFloat(opening ? pl : pf), ph = CGFloat(opening ? pf : pl)
            samples.append(IslandShape(size: CGSize(width: a.size.width + (b.size.width - a.size.width) * pw,
                                                    height: max(geometry.notch.height * 0.8, a.size.height + (b.size.height - a.size.height) * ph)),
                                       radius: max(4, a.radius + (b.radius - a.radius) * ph)))
        }
        samples[samples.count - 1] = b
        let paths = samples.map { islandPath($0.size, radius: $0.radius) }
        let speed = max(prefs.notchAnimationSpeed, 0.1)
        for layer in [fill, glowMask, border, dropBorder, clipMask, alertMask, shadowShape] { keyframes(layer, "path", paths, duration / speed) }
        keyframes(shadowShape, "shadowPath", paths, duration / speed)
        flight = (samples, CACurrentMediaTime(), duration / speed)
    }

    private func keyframes(_ layer: CALayer, _ key: String, _ values: [CGPath], _ duration: CFTimeInterval) {
        layer.setValue(values.last, forKeyPath: key)
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = values
        a.duration = duration
        a.calculationMode = .linear
        layer.add(a, forKey: key)
    }

    #if DEBUG
    /// Size of the island as the render server currently shows it (for the debug harness).
    var presentedSize: CGSize { fill.presentation()?.path?.boundingBox.size ?? fill.path?.boundingBox.size ?? .zero }
    var presentedContentOpacity: Float { clip.layer?.presentation()?.opacity ?? 0 }
    /// What a click lands on in the middle of the tab bar where it's drawn now (for the harness).
    func debugTabBarHit() -> String {
        let below = geometry.expandedSize(for: state.tab).height + NotchGeometry.tabBarGap + NotchGeometry.tabBarHeight / 2
        return "tab=\(state.tab) " + debugHit(below: [below], x: 0)
    }

    /// What a click lands on at `points` below the island's top (for the harness).
    func debugHit(below points: [CGFloat], x: CGFloat) -> String {
        points.map { dy in
            let p = CGPoint(x: bounds.midX + x, y: bounds.maxY - dy)
            var chain: [String] = []
            var v = hitTest(convert(p, to: superview))
            while let view = v, view !== self { chain.append(String(describing: type(of: view)).prefix(40).description); v = view.superview }
            return "dy=\(Int(dy)): " + chain.joined(separator: " < ")
        }.joined(separator: "\n")
    }
    var debugState: String { "expanded=\(state.expanded) model=\(fill.path?.boundingBox.size ?? .zero) anims=\(fill.animationKeys() ?? [])" }
    #endif

    // MARK: - Content

    private static let blurName = "revealBlur"

    /// Opening: the content comes into focus (blur → sharp), grows from 92% at the top edge and
    /// fades in just behind the outline. Closing: it blurs and fades out ahead of it.
    private func revealContent(expanded: Bool, animated: Bool) {
        guard animated, let layer = clip.layer else {
            clip.alphaValue = expanded ? 1 : 0
            // While an alert shows or leaves, `revealAlert` owns the wings.
            if state.alert == nil && shownAlert == nil { collapsedHost.alphaValue = expanded ? 0 : 1 }
            clip.layer?.filters = nil
            return
        }
        let speed = Double(max(prefs.notchAnimationSpeed, 0.1))
        let duration = (expanded ? 0.34 : 0.12) / speed
        let delay = expanded ? 0.07 / speed : 0
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.name = Self.blurName
        blur?.setValue(0, forKey: kCIInputRadiusKey)
        clip.layerUsesCoreImageFilters = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // A resting zero-radius blur would still cost a pass per frame.
            if self?.state.expanded == expanded { self?.clip.layer?.filters = nil }
        }
        layer.filters = blur.map { [$0] }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let group = CAAnimationGroup()
        let focus = CABasicAnimation(keyPath: "filters.\(Self.blurName).inputRadius")
        focus.fromValue = expanded ? 10 : 0
        focus.toValue = expanded ? 0 : 6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = expanded ? 0 : 1
        fade.toValue = expanded ? 1 : 0
        var animations: [CAAnimation] = [focus, fade]
        if expanded {
            // Scale around the top centre (layer origin is bottom-left).
            let p = CGPoint(x: layer.bounds.midX, y: layer.bounds.maxY)
            var t = CATransform3DMakeTranslation(p.x, p.y, 0)
            t = CATransform3DScale(t, 0.92, 0.92, 1)
            t = CATransform3DTranslate(t, -p.x, -p.y, 0)
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = t
            grow.toValue = CATransform3DIdentity
            animations.append(grow)
        }
        group.animations = animations
        group.duration = duration
        group.beginTime = now + delay
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        layer.opacity = expanded ? 1 : 0
        layer.add(group, forKey: "reveal")
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = (expanded ? 0.1 : 0.2) / speed
            collapsedHost.animator().alphaValue = expanded || state.alert != nil ? 0 : 1
        }
    }

    // MARK: - Dropping files on the island

    /// Only over the island itself: the panel is sized for the tallest tab and mostly see-through,
    /// so a drag in the empty space under a short island used to count as on it.
    private func overIsland(_ sender: NSDraggingInfo) -> Bool {
        guard state.expanded else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let size = shownShape.size
        let island = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height, width: size.width, height: size.height)
        return island.insetBy(dx: -6, dy: -6).contains(p)
    }

    /// Lights the drop target while the drag is over the island, on the Files tab.
    private func trackDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        let inside = overIsland(sender)
        if state.dropTargeted != inside { state.dropTargeted = inside }
        if inside && state.tab != .shelf { state.tab = .shelf }
        return inside ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        state.dropCount = urls?.count ?? 0
        return trackDrag(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { trackDrag(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { state.dropTargeted = false }

    override func draggingEnded(_ sender: NSDraggingInfo) { state.dropTargeted = false }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { overIsland(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        state.dropTargeted = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        FileShelf.shared.add(urls)
        state.tab = .shelf
        return true
    }
}

/// The island's colours from Settings → Notch → Style. Closed, the island stays black and
/// borderless so it matches the hardware notch.
private struct IslandLook: CustomStringConvertible {
    let fill: NSColor
    let border: NSColor
    let borderWidth: CGFloat
    let glow: CGFloat
    let shadow: Double

    @MainActor
    init(_ style: StylePreferences, tint: NSColor?, expanded: Bool) {
        glow = style.notchGlow
        shadow = style.notchShadow
        borderWidth = style.notchBorderWidth
        guard expanded else {
            fill = .black
            border = .clear
            return
        }
        switch style.notchFill {
        case .artwork: fill = tint?.blended(withFraction: 0.78, of: .black) ?? .black
        case .custom: fill = NSColor(style.notchFillColor)
        case .accent: fill = NSColor(SwitchPreferences.shared.accent.color).blended(withFraction: 0.7, of: .black) ?? .black
        case .standard, .off: fill = .black
        }
        switch style.notchBorder {
        case .artwork: border = (tint ?? .clear).withAlphaComponent(tint == nil ? 0 : 0.35)
        case .accent: border = NSColor(SwitchPreferences.shared.accent.color).withAlphaComponent(0.7)
        case .custom: border = NSColor(style.notchBorderColor)
        case .standard: border = NSColor.white.withAlphaComponent(0.12)
        case .off: border = .clear
        }
    }

    var description: String { "\(fill)|\(border)|\(borderWidth)|\(glow)|\(shadow)" }
}

/// A view that lets every click through to whatever is under it.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
