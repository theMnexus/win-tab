import AppKit
import SwiftUI

/// A live, scaled-down picture of win-tab's Dock on a mock desktop, drawn with the real layout
/// maths and the current settings; a pretend pointer glides along it so hover effects show.
struct DockLivePreview: View {
    @ObservedObject private var prefs = SwitchPreferences.shared
    private static let scale: CGFloat = 0.5
    private static let height: CGFloat = 200

    /// A few apps every Mac has, for realistic icons.
    private static let icons: [NSImage] = [
        "/System/Library/CoreServices/Finder.app", "/Applications/Safari.app", "/System/Applications/Music.app",
        "/System/Applications/Calendar.app", "/System/Applications/Messages.app", "/System/Applications/Notes.app",
        "/System/Applications/Photos.app",
    ].map { NSImage.flattenedIcon(NSWorkspace.shared.icon(forFile: $0)) }

    private enum Item { case app(Int), divider, widget }
    private static let items: [Item] = [.app(0), .app(1), .app(2), .divider, .widget, .app(3), .app(4), .app(5), .app(6)]

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation) { ctx in
                let screen = CGSize(width: g.size.width, height: Self.height)
                ZStack(alignment: .topLeading) {
                    wallpaper
                    menuBar(width: screen.width)
                    dock(in: screen, time: ctx.date.timeIntervalSinceReferenceDate)
                }
                .frame(width: screen.width, height: screen.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.1)))
            }
        }
        .frame(height: Self.height)
    }

    private var wallpaper: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.05, green: 0.2, blue: 0.35), Color(red: 0.55, green: 0.3, blue: 0.4)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func menuBar(width: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.35))
            HStack(spacing: 8) {
                Image(systemName: "apple.logo").font(.system(size: 8))
                ForEach(["File", "Edit", "View"], id: \.self) { Text($0).font(.system(size: 7, weight: .medium)) }
                Spacer()
                Text("14:02").font(.system(size: 7, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
        }
        .frame(width: width, height: 14)
    }

    private func layout(edge: ScreenEdge) -> CustomDockLayout {
        let s = Self.scale, icon = CGFloat(prefs.customDockIconSize) * s
        let effect = prefs.customDockHoverEffect
        var metrics = CustomDockLayout.Metrics(padding: prefs.customDockPadding * s, spacing: prefs.customDockSpacing * s,
                                               spread: prefs.customDockSpread, rise: 0,
                                               handle: prefs.customDockGripMode == .never ? 0 : CustomDockLayout.handleLength * s,
                                               hoverZoom: prefs.customDockHoverZoom)
        if effect == .lift || effect == .glow { metrics.rise = icon * CustomDockLayout.liftRise + icon * (metrics.hoverZoom - 1) }
        let gap = prefs.customDockWidgetGap * s
        let insets = Self.items.map { item -> CGFloat in if case .widget = item { return gap }; return 0 }
        let lengths = zip(Self.items, insets).map { item, inset -> CGFloat in
            switch item {
            case .app: return icon
            case .divider: return icon * 0.2
            case .widget: return icon * (edge.isVertical ? 1 : 2) + inset * 2
            }
        }
        let magnifies = Self.items.map { item -> Bool in if case .app = item { return true }; return false }
        return CustomDockLayout(edge: edge, iconSize: icon,
                                maxScale: effect == .magnify ? max(1, prefs.customDockMagnifiedSize / prefs.customDockIconSize) : 1,
                                metrics: metrics, lengths: lengths, insets: insets, magnifies: magnifies)
    }

    private func dock(in screen: CGSize, time: Double) -> some View {
        let placement: (edge: ScreenEdge, offset: Double) = NSScreen.screens.first.map { prefs.dockPlacement(for: $0) }
            ?? (prefs.customDockEdge, prefs.customDockOffset)
        let l = layout(edge: placement.edge)
        let sweep = CGFloat(0.5 + 0.5 * sin(time * 0.8))
        let first = l.rests[0], last = l.rests[l.count - 1]
        let along: CGFloat = first + (last - first) * sweep
        let frames = l.frames(pointerAlong: along)
        let hovered = l.index(atAlong: along)
        let origin = panelOrigin(l.panelSize, in: screen, edge: placement.edge, offset: placement.offset)
        let handle = l.metrics.handle
        return ZStack(alignment: .topLeading) {
            bar(l.barRect(start: frames.barStart - handle, end: frames.barEnd))
            if handle > 0 { grip(l.handleRect(barStart: frames.barStart), vertical: l.edge.isVertical) }
            ForEach(Self.items.indices, id: \.self) { i in
                item(i, layout: l, frame: frames.items[i], hovered: hovered == i)
            }
        }
        .frame(width: l.panelSize.width, height: l.panelSize.height, alignment: .topLeading)
        .offset(x: origin.x, y: origin.y)
    }

    private func panelOrigin(_ size: CGSize, in screen: CGSize, edge: ScreenEdge, offset: Double) -> CGPoint {
        let m = prefs.customDockMargin * Self.scale, top: CGFloat = 14, t = CGFloat(offset)
        let usable = screen.height - top
        switch edge {
        case .bottom: return CGPoint(x: (screen.width - size.width) * t, y: screen.height - size.height - m)
        case .top: return CGPoint(x: (screen.width - size.width) * t, y: top + m)
        case .left: return CGPoint(x: m, y: top + (usable - size.height) * t)
        case .right: return CGPoint(x: screen.width - size.width - m, y: top + (usable - size.height) * t)
        }
    }

    private func bar(_ r: CGRect) -> some View {
        let radius = prefs.customDockCornerRadius * Self.scale
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return Group {
            switch prefs.customDockBarStyle {
            case .glass: shape.fill(.ultraThinMaterial).overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 0.6))
            case .blur: shape.fill(.regularMaterial)
            case .dark: shape.fill(Color.black.opacity(0.72))
            case .clear: shape.stroke(Color.white.opacity(0.3), lineWidth: 0.8)
            }
        }
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
    }

    private func grip(_ r: CGRect, vertical: Bool) -> some View {
        let long = (vertical ? r.width : r.height) * 0.5
        return Capsule().fill(Color.white.opacity(0.6))
            .frame(width: vertical ? long : 2, height: vertical ? 2 : long)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
    }

    @ViewBuilder
    private func item(_ i: Int, layout l: CustomDockLayout, frame: CustomDockLayout.Frame, hovered: Bool) -> some View {
        let rest = l.itemSize(i)
        let effect = prefs.customDockHoverEffect
        let isApp: Bool = { if case .app = Self.items[i] { return true }; return false }()
        let scale = isApp && hovered && (effect == .lift || effect == .glow) ? l.metrics.hoverZoom : frame.scale
        let rise = isApp && hovered && effect == .lift ? l.iconSize * CustomDockLayout.liftRise : 0
        let c = l.point(along: frame.center, across: l.across)
        let shown = CGSize(width: rest.width * scale, height: rest.height * scale)
        let away = l.awayFromEdge
        let anchor = anchored(center: c, rest: rest, shown: shown, edge: l.edge)
        Group {
            switch Self.items[i] {
            case .app(let n):
                Image(nsImage: Self.icons[n]).resizable().interpolation(.high)
                    .shadow(color: effect == .glow && hovered ? prefs.accent.color.opacity(0.8) : .clear, radius: 6)
            case .divider:
                Rectangle().fill(Color.white.opacity(0.3))
                    .frame(width: l.edge.isVertical ? shown.width * 0.8 : 1, height: l.edge.isVertical ? 1 : shown.height * 0.8)
            case .widget:
                widget(size: shown)
            }
        }
        .frame(width: shown.width, height: shown.height)
        .offset(x: anchor.x + away.x * rise, y: anchor.y + away.y * rise)
        if isApp && i % 3 != 2 && prefs.customDockIndicator != .none {
            let d = l.point(along: frame.center, across: l.indicatorAcross)
            let line = prefs.customDockIndicator == .line
            let size = line ? (l.edge.isVertical ? CGSize(width: 1.6, height: 6) : CGSize(width: 6, height: 1.6)) : CGSize(width: 2.4, height: 2.4)
            Capsule().fill(Color.white.opacity(0.8)).frame(width: size.width, height: size.height)
                .offset(x: d.x - size.width / 2, y: d.y - size.height / 2)
        }
    }

    private func widget(size: CGSize) -> some View {
        let light = prefs.customDockWidgetStyle == .light
        return RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.24, style: .continuous)
            .fill(light ? AnyShapeStyle(Color.white.opacity(0.95)) : prefs.customDockWidgetStyle == .glass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(white: 0.1)))
            .overlay(
                Text("14:02").font(.system(size: min(size.width, size.height) * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(light ? Color.black.opacity(0.8) : .white)
            )
    }

    private func anchored(center: CGPoint, rest: CGSize, shown: CGSize, edge: ScreenEdge) -> CGPoint {
        switch edge {
        case .bottom: return CGPoint(x: center.x - shown.width / 2, y: center.y + rest.height / 2 - shown.height)
        case .top: return CGPoint(x: center.x - shown.width / 2, y: center.y - rest.height / 2)
        case .left: return CGPoint(x: center.x - rest.width / 2, y: center.y - shown.height / 2)
        case .right: return CGPoint(x: center.x + rest.width / 2 - shown.width, y: center.y - shown.height / 2)
        }
    }
}

/// The notch closed (with a song beside it) and open, side by side.
struct NotchIllustration: View {
    @ObservedObject private var prefs = SwitchPreferences.shared

    var body: some View {
        HStack(spacing: 14) {
            panel(title: "Closed", subtitle: "What's playing sits beside the notch") { closed }
            panel(title: "Hover", subtitle: "Controls, Shelf, Clipboard, Timer") { open }
        }
        .frame(height: 170)
    }

    private func panel<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.3), Color(red: 0.45, green: 0.25, blue: 0.4)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.black.opacity(0.35)).frame(height: 14)
                content()
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var closed: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
                .frame(width: 11, height: 11)
            Spacer(minLength: 58)
            HStack(spacing: 1.5) {
                ForEach([6.0, 9, 5, 8], id: \.self) { h in Capsule().fill(Color.pink).frame(width: 1.8, height: h) }
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 120, height: 18)
        .background(NotchShape(bottomRadius: 7).fill(Color.black))
    }

    private var open: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(["house.fill", "tray.fill", "doc.on.clipboard.fill", "timer"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 6.5)).foregroundStyle(.white.opacity($0 == "house.fill" ? 1 : 0.5))
                }
                Spacer()
                Text("80%").font(.system(size: 6.5, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 80, height: 5)
                    Capsule().fill(Color.white.opacity(0.4)).frame(width: 50, height: 4)
                    Capsule().fill(Color.pink).frame(width: 110, height: 2.5)
                    HStack(spacing: 10) {
                        ForEach(["backward.fill", "pause.fill", "forward.fill"], id: \.self) {
                            Image(systemName: $0).font(.system(size: 7)).foregroundStyle(.white)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(width: 200)
        .background(NotchShape(bottomRadius: 14).fill(Color.black))
    }
}
