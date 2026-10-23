import SwiftUI

/// A ring that fills to the level around the alert's symbol; fills in when it appears.
struct LevelGauge: View {
    let level: Double?
    let color: Color
    let symbol: String
    var size: CGFloat = 46
    var lineWidth: CGFloat = 4
    var track: Color = .white.opacity(0.14)
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle().trim(from: 0, to: shown)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.7), radius: lineWidth)
            Image(systemName: symbol)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, isActive: color == .red)
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.86).delay(0.12)) { shown = level ?? 1 } }
        .onChange(of: level) { _, new in withAnimation(.easeOut(duration: 0.4)) { shown = new ?? 1 } }
    }
}

/// A bar that fills to the level with a soft glow; fills in when it appears.
struct LevelBarGlow: View {
    let level: Double
    let color: Color
    var track: Color = .white.opacity(0.14)
    var height: CGFloat = 5
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * min(max(shown, 0), 1)))
                    .shadow(color: color.opacity(0.6), radius: height)
            }
        }
        .frame(height: height)
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.86).delay(0.12)) { shown = level } }
        .onChange(of: level) { _, new in withAnimation(.easeOut(duration: 0.4)) { shown = new } }
    }
}

/// The alert bubble in the chosen theme; also the preview in Settings → Battery → General.
struct AlertBubbleView: View {
    let alert: NotchAlert
    var theme: BatteryPreferences.BubbleTheme = .glass
    var scale: CGFloat = 1
    var closable = true
    var close: () -> Void = {}

    static func size(_ theme: BatteryPreferences.BubbleTheme) -> CGSize {
        switch theme {
        case .glass: return CGSize(width: 380, height: 80)
        case .minimal: return CGSize(width: 330, height: 56)
        case .vivid: return CGSize(width: 360, height: 104)
        }
    }

    var body: some View {
        let s = Self.size(theme)
        Group {
            switch theme {
            case .glass: glass
            case .minimal: minimal
            case .vivid: vivid
            }
        }
        .frame(width: s.width, height: s.height)
        .scaleEffect(scale)
        .frame(width: s.width * scale, height: s.height * scale)
        .environment(\.colorScheme, .dark)
    }

    /// The app's icon for a notification, else the level gauge.
    @ViewBuilder private func leadingIcon(size: CGFloat) -> some View {
        if let app = alert.appIcon, let icon = AppIcons.icon(bundleID: app) {
            Image(nsImage: icon).resizable().frame(width: size * 0.86, height: size * 0.86)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .frame(width: size, height: size)
        } else {
            LevelGauge(level: alert.level, color: alert.color, symbol: alert.symbol, size: size)
        }
    }

    // MARK: Glass

    private var glass: some View {
        HStack(spacing: 14) {
            leadingIcon(size: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                if !alert.detail.isEmpty {
                    Text(alert.detail).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if closable { CloseButton(action: close) }
        }
        .padding(.leading, 15).padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { GlassCapsule(tint: alert.color) }
        .shadow(color: alert.color.opacity(0.3), radius: 22, y: 8)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    // MARK: Minimal

    private var minimal: some View {
        HStack(spacing: 10) {
            if alert.appIcon != nil {
                leadingIcon(size: 24)
            } else {
                Image(systemName: alert.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(alert.color)
            }
            Text(alert.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            if !alert.detail.isEmpty {
                Text(alert.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if closable { CloseButton(size: 24, action: close) }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color.black.opacity(0.86)))
        .overlay(alignment: .bottom) {
            if let level = alert.level {
                LevelBarGlow(level: level, color: alert.color, track: .clear, height: 2.5).padding(.horizontal, 26).padding(.bottom, 4)
            }
        }
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
    }

    // MARK: Vivid

    private var vivid: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                if alert.appIcon != nil {
                    leadingIcon(size: 40)
                } else {
                    Text(alert.badge).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if !alert.detail.isEmpty {
                        Text(alert.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if closable {
                    CloseButton(tint: .white, action: close)
                } else {
                    Image(systemName: alert.symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                }
            }
            if let level = alert.level {
                LevelBarGlow(level: level, color: .white, track: .white.opacity(0.25), height: 6)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                shape.fill(Color(white: 0.06))
                shape.fill(LinearGradient(colors: [alert.color.opacity(0.95), alert.color.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        }
        .shadow(color: alert.color.opacity(0.45), radius: 24, y: 10)
    }
}

/// Liquid Glass capsule tinted with the alert's colour (a material on older macOS), with a light
/// rim like real glass.
private struct GlassCapsule: View {
    let tint: Color

    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(tint.opacity(0.16)), in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.black.opacity(0.35))
            }
            Capsule().fill(LinearGradient(colors: [tint.opacity(0.22), .clear], startPoint: .leading, endPoint: .center))
            Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06), tint.opacity(0.45)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
    }
}

private struct CloseButton: View {
    var size: CGFloat = 30
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(tint.opacity(0.85))
                .frame(width: size, height: size)
                .background(Circle().fill(tint.opacity(hovering ? 0.22 : 0.1)))
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// What the closed island shows for an alert. Expanded: gauge and figure in the wings, title,
/// detail and level bar under the notch. Compact: everything in the wings.
struct NotchAlertBody: View {
    let alert: NotchAlert
    let notch: CGSize
    let style: BatteryPreferences.NotchAlertStyle
    private var compact: Bool { style != .expanded }

    var body: some View {
        if style == .icon { iconOnly } else { full }
    }

    /// Just the app icon (or gauge) and a dot or figure in narrow wings: barely there.
    private var iconOnly: some View {
        HStack(spacing: 0) {
            if let app = alert.appIcon, let icon = AppIcons.icon(bundleID: app) {
                Image(nsImage: icon).resizable().frame(width: notch.height - 10, height: notch.height - 10)
            } else {
                LevelGauge(level: alert.level, color: alert.color, symbol: alert.symbol, size: notch.height - 12, lineWidth: 2)
            }
            Spacer(minLength: notch.width)
            if alert.appIcon != nil {
                Circle().fill(Color(red: 0.3, green: 0.6, blue: 1)).frame(width: 8, height: 8)
                    .shadow(color: Color(red: 0.3, green: 0.6, blue: 1).opacity(0.8), radius: 4)
            } else {
                Text(alert.badge).font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(alert.color)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: notch.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var full: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let app = alert.appIcon, let icon = AppIcons.icon(bundleID: app) {
                    Image(nsImage: icon).resizable().frame(width: notch.height - 8, height: notch.height - 8)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                } else {
                    LevelGauge(level: alert.level, color: alert.color, symbol: alert.symbol, size: notch.height - 10, lineWidth: 2.5)
                }
                if compact {
                    Text(alert.short.isEmpty ? alert.title : alert.short)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                Spacer(minLength: notch.width)
                Text(alert.badge).font(.system(size: alert.appIcon == nil ? 14 : 11.5, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(alert.appIcon == nil ? alert.color : .white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .frame(height: notch.height)
            if !compact {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.title).font(.system(size: 13.5, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                        if !alert.detail.isEmpty {
                            Text(alert.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if let level = alert.level { LevelBarGlow(level: level, color: alert.color).frame(width: 70) }
                }
                .padding(.horizontal, 18)
                .frame(height: NotchGeometry.alertRow - 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The closed island's alert, kept on screen while it fades out after `state.alert` clears.
struct NotchAlertContent: View {
    @ObservedObject var state: NotchState
    let geometry: NotchGeometry
    @ObservedObject private var prefs = BatteryPreferences.shared
    @State private var shown: NotchAlert?

    var body: some View {
        Group {
            if let alert = shown {
                let style = alert.style ?? prefs.notchAlertStyle
                NotchAlertBody(alert: alert, notch: geometry.notch, style: style)
                    .id(alert.id)
                    .frame(width: geometry.alertSize(style).width - NotchGeometry.flare * 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { shown = state.alert }
        .onChange(of: state.alert) { _, new in if let new { shown = new } }
    }
}

/// A notch alert drawn in Settings, as it would hang from the top of the screen.
struct NotchAlertPreview: View {
    let alert: NotchAlert
    let style: BatteryPreferences.NotchAlertStyle
    private let notch = CGSize(width: 190, height: 32)

    var body: some View {
        let width: CGFloat = switch style {
        case .expanded: max(notch.width + 200, 360)
        case .compact: notch.width + NotchGeometry.compactWing * 2
        case .icon: notch.width + NotchGeometry.iconWing * 2
        }
        let height = style == .expanded ? notch.height + NotchGeometry.alertRow : notch.height
        let shape = NotchShape(bottomRadius: style == .expanded ? 22 : notch.height * 0.38, flare: NotchGeometry.flare)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
                .overlay(shape.stroke(alert.color.opacity(0.35), lineWidth: 1))
                .frame(width: width + NotchGeometry.flare * 2, height: height)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
            NotchAlertBody(alert: alert, notch: notch, style: style).frame(width: width, height: height)
        }
        .environment(\.colorScheme, .dark)
    }
}
