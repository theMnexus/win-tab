import SwiftUI

/// Tiny drawn mockups beside each Dock setting, so the effect is visible at a glance
/// instead of only described. Pure shapes: they follow the accent color and both themes.
struct DockIllustration: View {
    enum Kind { case previews, labels, badges, clickToHide, scroll, customDock }

    let kind: Kind
    let accent: Color
    static let size = CGSize(width: 86, height: 56)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.35), accent.opacity(0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            content
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .previews:
            VStack(spacing: 4) {
                card { HStack(spacing: 3) { thumb; thumb } }
                dock(highlight: 1)
            }
        case .labels:
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    pill.overlay(Rectangle().fill(Color.red.opacity(0.85)).frame(height: 1.5).rotationEffect(.degrees(-12)))
                    Image(systemName: "arrow.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                    card { VStack(alignment: .leading, spacing: 2) { bar(20); bar(14, opacity: 0.35) } }
                }
                dock(highlight: 1)
            }
        case .badges:
            HStack(spacing: 6) {
                appIcon(badge: "3")
                appIcon(badge: "12")
            }
        case .clickToHide:
            VStack(spacing: 5) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.6)).frame(width: 22, height: 14)
                    Image(systemName: "arrow.down.right").font(.system(size: 7, weight: .bold))
                    Image(systemName: "eye.slash").font(.system(size: 9))
                }
                .foregroundStyle(.primary.opacity(0.7))
                ZStack(alignment: .topTrailing) {
                    dock(highlight: 1)
                    Image(systemName: "cursorarrow").font(.system(size: 10)).offset(x: -18, y: -4)
                }
            }
        case .customDock:
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.18)).frame(width: 60, height: 36)
                VStack(spacing: 3) {
                    ForEach(0..<3) { i in
                        RoundedRectangle(cornerRadius: 2).fill(i == 1 ? accent : Color.white.opacity(0.6)).frame(width: 7, height: 7)
                    }
                }
                .padding(3)
                .background(Capsule().fill(Color.white.opacity(0.25)))
                .offset(x: -22)
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                    .offset(x: 8)
            }
        case .scroll:
            VStack(spacing: 5) {
                ZStack {
                    ForEach(0..<3) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.35 + Double(i) * 0.2))
                            .frame(width: 26, height: 16)
                            .offset(x: CGFloat(i - 1) * 6, y: CGFloat(i - 1) * -3)
                    }
                }
                HStack(spacing: 3) {
                    dock(highlight: 1)
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 8, weight: .bold)).foregroundStyle(accent)
                }
            }
        }
    }

    private func dock(highlight: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i == highlight ? accent : Color.white.opacity(0.55))
                    .frame(width: i == highlight ? 9 : 7, height: i == highlight ? 9 : 7)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.25)))
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.25)))
    }

    private var thumb: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.7)).frame(width: 14, height: 9)
    }

    private var pill: some View {
        Capsule().fill(Color.black.opacity(0.35)).frame(width: 22, height: 8)
    }

    private func bar(_ width: CGFloat, opacity: Double = 0.7) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(opacity)).frame(width: width, height: 3)
    }

    private func appIcon(badge: String) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(0.7))
            .frame(width: 24, height: 24)
            .overlay(alignment: .topTrailing) {
                Text(badge)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2.5)
                    .frame(minWidth: 11, minHeight: 11)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 4, y: -4)
            }
    }
}
