import AppKit
import SwiftUI

/// A widget drawn in a Dock slot: `size` is its full rect, thickness = the icon size.
struct DockWidgetView: View {
    let kind: DockWidgetKind
    let size: CGSize
    let vertical: Bool

    private var side: CGFloat { min(size.width, size.height) }
    private var radius: CGFloat { side * 0.24 }

    var body: some View {
        Group {
            switch kind {
            case .nowPlaying: DockNowPlayingWidget(side: side, vertical: vertical)
            case .clock: DockClockWidget(side: side, vertical: vertical)
            case .calendar: DockDateWidget(side: side)
            case .battery: DockBatteryWidget(side: side)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
    }
}

/// Card behind the glanceable widgets, in the style chosen in Settings (dark by default).
private struct WidgetCard<Content: View>: View {
    @ViewBuilder let content: Content
    @ObservedObject private var prefs = SwitchPreferences.shared

    var body: some View {
        ZStack {
            switch prefs.customDockWidgetStyle {
            case .dark: LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            case .light: LinearGradient(colors: [Color.white.opacity(0.97), Color(white: 0.9)], startPoint: .top, endPoint: .bottom)
            case .glass: Rectangle().fill(.ultraThinMaterial)
            }
            content.foregroundStyle(prefs.customDockWidgetStyle == .light ? Color.black.opacity(0.85) : Color.white.opacity(0.95))
        }
        .environment(\.colorScheme, prefs.customDockWidgetStyle == .light ? .light : .dark)
    }
}

private struct DockClockWidget: View {
    let side: CGFloat
    let vertical: Bool
    var body: some View {
        WidgetCard {
            TimelineView(.everyMinute) { ctx in
                VStack(spacing: 0) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: side * (vertical ? 0.28 : 0.36), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if !vertical {
                        Text(ctx.date, format: .dateTime.weekday(.abbreviated))
                            .font(.system(size: side * 0.2, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .minimumScaleFactor(0.5)
            }
        }
    }
}

private struct DockDateWidget: View {
    let side: CGFloat
    var body: some View {
        WidgetCard {
            TimelineView(.everyMinute) { ctx in
                VStack(spacing: 0) {
                    Text(ctx.date, format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: side * 0.2, weight: .bold))
                        .foregroundStyle(.red)
                        .textCase(.uppercase)
                    Text(ctx.date, format: .dateTime.day())
                        .font(.system(size: side * 0.46, weight: .regular))
                }
            }
        }
    }
}

private struct DockBatteryWidget: View {
    let side: CGFloat
    @ObservedObject private var battery = BatteryMonitor.shared
    var body: some View {
        let state = battery.state
        let low = (state?.percent ?? 100) <= 20 && state?.charging != true
        WidgetCard {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.14), lineWidth: side * 0.09)
                Circle()
                    .trim(from: 0, to: CGFloat(state?.percent ?? 0) / 100)
                    .stroke(low ? Color.red : Color.green, style: StrokeStyle(lineWidth: side * 0.09, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    if state?.charging == true {
                        Image(systemName: "bolt.fill").font(.system(size: side * 0.16)).foregroundStyle(.green)
                    }
                    Text(state.map { "\($0.percent)" } ?? "–")
                        .font(.system(size: side * 0.24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .padding(side * 0.14)
        }
    }
}

/// Dark card tinted by the artwork: song, app, progress and controls for whatever is playing.
private struct DockNowPlayingWidget: View {
    let side: CGFloat
    let vertical: Bool
    @ObservedObject private var nowPlaying = NowPlayingMonitor.shared

    private var accent: Color { nowPlaying.tint ?? .white }

    var body: some View {
        let track = nowPlaying.track
        ZStack {
            Color(white: 0.08)
            if let tint = nowPlaying.tint {
                LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
            }
            if vertical {
                VStack(spacing: side * 0.06) {
                    NotchArtwork(size: side * 0.62, radius: side * 0.12)
                    controls(track, compact: true)
                }
            } else {
                HStack(spacing: side * 0.14) {
                    NotchArtwork(size: side * 0.7, radius: side * 0.14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track?.title ?? "Nothing playing")
                            .font(.system(size: max(8, side * 0.21), weight: .semibold))
                        Text(track.map { $0.artist.isEmpty ? $0.player : $0.artist } ?? "Music, Spotify, YouTube…")
                            .font(.system(size: max(7, side * 0.17)))
                            .foregroundStyle(.white.opacity(0.6))
                        if let track, track.duration > 0 {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Capsule().fill(Color.white.opacity(0.2))
                                    .overlay(alignment: .leading) {
                                        GeometryReader { g in
                                            Capsule().fill(accent).frame(width: g.size.width * track.position(at: ctx.date) / track.duration)
                                        }
                                    }
                                    .frame(height: 2.5)
                            }
                            .padding(.top, side * 0.06)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    controls(track, compact: false)
                }
                .padding(.horizontal, side * 0.14)
            }
        }
        .foregroundStyle(.white)
    }

    private func controls(_ track: NowPlayingMonitor.Track?, compact: Bool) -> some View {
        HStack(spacing: side * 0.04) {
            if !compact { button("backward.fill", .previous) }
            button(track?.playing == true ? "pause.fill" : "play.fill", .playpause, big: true)
            if !compact { button("forward.fill", .next) }
        }
        .disabled(track == nil)
        .opacity(track == nil ? 0.35 : 1)
    }

    private func button(_ symbol: String, _ command: NowPlayingMonitor.Command, big: Bool = false) -> some View {
        Button { nowPlaying.send(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: max(9, side * (big ? 0.28 : 0.2))))
                .frame(width: side * 0.34, height: side * 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Shrinks and brightens under the finger, so controls feel alive without a hover state.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Several widgets in one slot, like a Smart Stack: scroll over it to flip through them, and it
/// turns to Now Playing on its own while music plays (unless you flipped it in the last minute).
struct DockSmartStackView: View {
    private static let manualHold: TimeInterval = 60

    let kinds: [DockWidgetKind]
    let size: CGSize
    let vertical: Bool
    @ObservedObject private var nowPlaying = NowPlayingMonitor.shared
    @State private var index = 0
    @State private var flippedAt = Date.distantPast

    private var shown: DockWidgetKind? {
        guard !kinds.isEmpty else { return nil }
        let manual = Date().timeIntervalSince(flippedAt) < Self.manualHold
        if !manual, nowPlaying.track?.playing == true, kinds.contains(.nowPlaying) { return .nowPlaying }
        return kinds[min(index, kinds.count - 1)]
    }

    var body: some View {
        ZStack(alignment: vertical ? .bottom : .trailing) {
            if let kind = shown {
                DockWidgetView(kind: kind, size: size, vertical: vertical)
                    .id(kind)
                    .transition(.asymmetric(insertion: .move(edge: vertical ? .trailing : .bottom).combined(with: .opacity), removal: .opacity))
            } else {
                RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.22).fill(Color.white.opacity(0.3))
            }
            if kinds.count > 1 { dots.padding(3) }
        }
        .frame(width: size.width, height: size.height)
        .overlay(ScrollCatcher { flip($0) })
        .animation(.easeOut(duration: 0.2), value: shown)
    }

    private var dots: some View {
        let layout = vertical ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        return layout {
            ForEach(Array(kinds.enumerated()), id: \.offset) { i, kind in
                Circle().fill(Color.black.opacity(kind == shown ? 0.6 : 0.2)).frame(width: 3, height: 3)
                    .onTapGesture { index = i; flippedAt = Date() }
            }
        }
    }

    private func flip(_ forward: Bool) {
        guard kinds.count > 1 else { return }
        let current = shown.flatMap { kinds.firstIndex(of: $0) } ?? index
        index = (current + (forward ? 1 : -1) + kinds.count) % kinds.count
        flippedAt = Date()
    }
}

/// Takes scroll-wheel events only: clicks and hovers go through to the views below.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (Bool) -> Void

    final class View: NSView {
        var onScroll: (Bool) -> Void = { _ in }
        private var accumulated: CGFloat = 0
        private static let step: CGFloat = 12

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            accumulated += event.scrollingDeltaY + event.scrollingDeltaX
            guard abs(accumulated) >= Self.step || !event.hasPreciseScrollingDeltas else { return }
            onScroll(accumulated < 0)
            accumulated = 0
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) { view.onScroll = onScroll }
}
