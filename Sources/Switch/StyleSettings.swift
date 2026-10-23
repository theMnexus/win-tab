import SwiftUI

// Settings rows for StylePreferences: the Dock's style and reveal bar, the notch's style and
// the switcher window's style.

/// Colour well on the right of a settings row.
struct SettingsColor: View {
    let title: String
    var detail: String = ""
    @Binding var color: Color
    var opacity = true

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            ColorPicker("", selection: $color, supportsOpacity: opacity).labelsHidden()
        }
    }
}

/// A paint picker, plus a colour well when Custom is chosen.
private struct PaintRow: View {
    let title: String
    var detail: String = ""
    @Binding var paint: StylePreferences.Paint
    @Binding var color: Color
    let options: [StylePreferences.Paint]

    var body: some View {
        SettingsSegmented(title: title, detail: detail, selection: $paint, options: options, label: \.label, width: CGFloat(options.count) * 72)
        if paint == .custom {
            SettingsColor(title: "\(title) colour", color: $color)
        }
    }
}

/// Colour, thickness and length of the bar left at the edge while the Dock is hidden.
struct DockRevealBarStyleRows: View {
    @ObservedObject private var prefs = SwitchPreferences.shared
    @ObservedObject private var style = StylePreferences.shared

    var body: some View {
        if prefs.customDockRevealBar == .custom {
            SettingsColor(title: "Bar colour", detail: "Any colour, with transparency.", color: $style.revealColor)
        }
        if prefs.customDockRevealBar != .none {
            SettingsSlider(title: "Bar thickness", value: String(format: "%.1f pt", style.revealThickness), number: $style.revealThickness, range: 1.5...8, step: 0.5)
            SettingsSlider(title: "Bar length", value: String(format: "%.0f%% of the Dock", style.revealLength * 100), number: $style.revealLength, range: 0.1...2, step: 0.05)
            SettingsSlider(title: "Distance from edge", value: String(format: "%.0f pt", style.revealGap), number: $style.revealGap, range: 0...16, step: 1)
            SettingsSlider(title: "Hover area above the bar", value: String(format: "%.0f pt", style.revealHoverHeight), number: $style.revealHoverHeight, range: 2...40, step: 1)
            SettingsSlider(title: "Faded when idle", value: style.revealIdleOpacity >= 1 ? "Off" : String(format: "%.0f%% visible, full on hover", style.revealIdleOpacity * 100),
                           number: $style.revealIdleOpacity, range: 0.1...1, step: 0.05)
        }
    }
}

struct DockStyleSection: View {
    @ObservedObject private var style = StylePreferences.shared

    var body: some View {
        SettingsSection(title: "Style", subtitle: "Colours on top of the bar style above.") {
            SettingsCard {
                SettingsColor(title: "Tint", detail: "With the Glass bar it colours the glass itself; otherwise it's laid over the bar. Lower the opacity for a hint of colour.", color: $style.dockTint)
                SettingsSegmented(title: "Liquid Glass", detail: "Clear lets more of the desktop show through. Also used by the ⌘-Tab window, hover cards and group grids set to Liquid Glass.",
                                  selection: $style.glass, options: StylePreferences.Glass.allCases, label: \.label, width: 180)
                SettingsDivider()
                PaintRow(title: "Border", paint: $style.dockBorder, color: $style.dockBorderColor, options: [.standard, .accent, .custom, .off])
                if style.dockBorder == .accent || style.dockBorder == .custom {
                    SettingsSlider(title: "Border width", value: String(format: "%.1f pt", style.dockBorderWidth), number: $style.dockBorderWidth, range: 0.5...4, step: 0.5)
                }
                SettingsDivider()
                SettingsSlider(title: "Shadow", value: style.dockShadow == 0 ? "Off" : String(format: "%.0f%%", style.dockShadow * 100), number: $style.dockShadow, range: 0...1, step: 0.05)
                SettingsDivider()
                PaintRow(title: "Running dots", paint: $style.dockIndicator, color: $style.dockIndicatorColor, options: [.standard, .accent, .custom])
            }
        }
    }
}

struct NotchStyleSection: View {
    @ObservedObject private var style = StylePreferences.shared

    var body: some View {
        SettingsSection(title: "Style", subtitle: "Closed, the island stays black so it matches the notch; these show when it opens and beside it.") {
            SettingsCard {
                PaintRow(title: "Background", detail: "Artwork: a dark shade of the song's colour.", paint: $style.notchFill, color: $style.notchFillColor, options: [.standard, .artwork, .accent, .custom])
                SettingsDivider()
                PaintRow(title: "Border", paint: $style.notchBorder, color: $style.notchBorderColor, options: [.artwork, .accent, .custom, .standard, .off])
                if style.notchBorder != .off {
                    SettingsSlider(title: "Border width", value: String(format: "%.1f pt", style.notchBorderWidth), number: $style.notchBorderWidth, range: 0.5...4, step: 0.5)
                }
                SettingsDivider()
                SettingsSlider(title: "Artwork glow", value: style.notchGlow == 0 ? "Off" : String(format: "%.0f%%", style.notchGlow * 100), number: $style.notchGlow, range: 0...1, step: 0.05)
                SettingsSlider(title: "Shadow", value: style.notchShadow == 0 ? "Off" : String(format: "%.0f%%", style.notchShadow * 100), number: $style.notchShadow, range: 0...1, step: 0.05)
                SettingsDivider()
                PaintRow(title: "Text beside it", detail: "Time, date, Wi-Fi and battery.", paint: $style.notchText, color: $style.notchTextColor, options: [.standard, .artwork, .accent, .custom])
                PaintRow(title: "Music bars", paint: $style.notchBars, color: $style.notchBarsColor, options: [.artwork, .accent, .custom])
            }
        }
    }
}

struct WindowStyleSection: View {
    @ObservedObject private var prefs = SwitchPreferences.shared
    @ObservedObject private var style = StylePreferences.shared

    var body: some View {
        SettingsSection(title: "Window style", subtitle: "The ⌘-Tab window.") {
            preview
            SettingsCard {
                SettingsColor(title: "Tint", detail: "With Liquid Glass it colours the glass itself; otherwise it's laid over the background.", color: $style.windowTint)
                SettingsSegmented(title: "Liquid Glass", selection: $style.glass, options: StylePreferences.Glass.allCases, label: \.label, width: 180)
                SettingsSlider(title: "Corner radius", value: "\(Int(style.windowRadius)) pt", number: $style.windowRadius, range: 4...32)
                SettingsDivider()
                PaintRow(title: "Border", paint: $style.windowBorder, color: $style.windowBorderColor, options: [.off, .accent, .custom])
                if style.windowBorder != .off {
                    SettingsSlider(title: "Border width", value: String(format: "%.1f pt", style.windowBorderWidth), number: $style.windowBorderWidth, range: 0.5...4, step: 0.5)
                }
                SettingsDivider()
                SettingsSegmented(title: "Selection", detail: "Soft: light fill and ring. Solid: strong fill. Outline: ring only. Glow: fill with a halo.",
                                  selection: $style.windowSelection, options: StylePreferences.Selection.allCases, label: \.label)
            }
            HStack {
                Spacer()
                Button("Reset all styles") { style.reset() }.controlSize(.small)
            }
        }
    }

    /// A small switcher: three tiles with the middle one selected.
    private var preview: some View {
        let accent = prefs.accent.color
        return HStack(spacing: 10) {
            ForEach(0..<3) { i in
                let selected = i == 1
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 70, height: 46)
                    .padding(5)
                    .background {
                        if selected && style.windowSelection != .outline {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(accent.opacity(style.windowSelection == .solid ? 0.55 : 0.22))
                                .shadow(color: style.windowSelection == .glow ? accent.opacity(0.8) : .clear, radius: 10)
                        }
                    }
                    .overlay {
                        if selected && style.windowSelection != .solid {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(accent.opacity(style.windowSelection == .soft ? 0.7 : 1), lineWidth: style.windowSelection == .soft ? 1 : 2)
                        }
                    }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .background(style.windowTint)
        .clipShape(RoundedRectangle(cornerRadius: style.windowRadius, style: .continuous))
        .overlay {
            if let border = style.resolve(style.windowBorder, custom: style.windowBorderColor) {
                RoundedRectangle(cornerRadius: style.windowRadius, style: .continuous).strokeBorder(border, lineWidth: style.windowBorderWidth)
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.36), Color(red: 0.42, green: 0.26, blue: 0.4)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}
