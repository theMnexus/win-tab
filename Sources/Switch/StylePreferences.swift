import AppKit
import SwiftUI

/// Colours and extra looks for the Dock (bar, running dots, reveal bar), the notch and the
/// switcher window. Kept apart from `SwitchPreferences`, which holds behaviour. Colours are
/// stored as sRGB "r g b a" strings.
@MainActor
final class StylePreferences: ObservableObject {
    static let shared = StylePreferences()

    /// Where a colour comes from. Each setting offers the cases that make sense for it.
    enum Paint: String, CaseIterable, Identifiable {
        /// The built-in look.
        case standard
        case accent
        /// The playing song's artwork colour.
        case artwork
        case custom
        case off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .standard: return "Default"
            case .accent: return "Accent"
            case .artwork: return "Artwork"
            case .custom: return "Custom"
            case .off: return "Off"
            }
        }
    }

    /// Liquid Glass variant (macOS 26): Clear lets more of what's behind show through.
    enum Glass: String, CaseIterable, Identifiable {
        case regular, clear
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum Selection: String, CaseIterable, Identifiable {
        case soft, solid, outline, glow
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @Published var glass: Glass { didSet { save(glass.rawValue, "glass") } }

    // MARK: Dock

    @Published var revealColor: Color { didSet { save(revealColor, "revealColor") } }
    @Published var revealThickness: Double { didSet { save(revealThickness, "revealThickness") } }
    /// Share of the Dock's length the reveal bar spans (past 100% it reaches beyond the Dock's ends).
    @Published var revealLength: Double { didSet { save(revealLength, "revealLength") } }
    /// Points between the reveal bar and the screen edge.
    @Published var revealGap: Double { didSet { save(revealGap, "revealGap") } }
    /// Points above the bar that still count as hovering it.
    @Published var revealHoverHeight: Double { didSet { save(revealHoverHeight, "revealHoverHeight") } }
    /// How visible the reveal bar is while the pointer is away; hovering brings it to full.
    @Published var revealIdleOpacity: Double { didSet { save(revealIdleOpacity, "revealIdleOpacity") } }
    /// Colour laid over the Dock's bar; clear = none.
    @Published var dockTint: Color { didSet { save(dockTint, "dockTint") } }
    @Published var dockBorder: Paint { didSet { save(dockBorder.rawValue, "dockBorder") } }
    @Published var dockBorderColor: Color { didSet { save(dockBorderColor, "dockBorderColor") } }
    @Published var dockBorderWidth: Double { didSet { save(dockBorderWidth, "dockBorderWidth") } }
    @Published var dockShadow: Double { didSet { save(dockShadow, "dockShadow") } }
    @Published var dockIndicator: Paint { didSet { save(dockIndicator.rawValue, "dockIndicator") } }
    @Published var dockIndicatorColor: Color { didSet { save(dockIndicatorColor, "dockIndicatorColor") } }

    // MARK: Notch

    /// Open island's background; closed it stays black to match the hardware notch.
    @Published var notchFill: Paint { didSet { save(notchFill.rawValue, "notchFill") } }
    @Published var notchFillColor: Color { didSet { save(notchFillColor, "notchFillColor") } }
    @Published var notchBorder: Paint { didSet { save(notchBorder.rawValue, "notchBorder") } }
    @Published var notchBorderColor: Color { didSet { save(notchBorderColor, "notchBorderColor") } }
    @Published var notchBorderWidth: Double { didSet { save(notchBorderWidth, "notchBorderWidth") } }
    @Published var notchGlow: Double { didSet { save(notchGlow, "notchGlow") } }
    @Published var notchShadow: Double { didSet { save(notchShadow, "notchShadow") } }
    /// Time, date and other text beside the closed notch.
    @Published var notchText: Paint { didSet { save(notchText.rawValue, "notchText") } }
    @Published var notchTextColor: Color { didSet { save(notchTextColor, "notchTextColor") } }
    @Published var notchBars: Paint { didSet { save(notchBars.rawValue, "notchBars") } }
    @Published var notchBarsColor: Color { didSet { save(notchBarsColor, "notchBarsColor") } }

    // MARK: Switcher window

    @Published var windowTint: Color { didSet { save(windowTint, "windowTint") } }
    @Published var windowRadius: Double { didSet { save(windowRadius, "windowRadius") } }
    @Published var windowBorder: Paint { didSet { save(windowBorder.rawValue, "windowBorder") } }
    @Published var windowBorderColor: Color { didSet { save(windowBorderColor, "windowBorderColor") } }
    @Published var windowBorderWidth: Double { didSet { save(windowBorderWidth, "windowBorderWidth") } }
    @Published var windowSelection: Selection { didSet { save(windowSelection.rawValue, "windowSelection") } }

    private init() {
        let d = UserDefaults.standard
        func color(_ key: String, _ fallback: Color) -> Color { d.string(forKey: Self.key(key)).flatMap(Self.decode) ?? fallback }
        func number(_ key: String, _ fallback: Double) -> Double { d.object(forKey: Self.key(key)) as? Double ?? fallback }
        func paint(_ key: String, _ fallback: Paint) -> Paint { Paint(rawValue: d.string(forKey: Self.key(key)) ?? "") ?? fallback }
        glass = Glass(rawValue: d.string(forKey: Self.key("glass")) ?? "") ?? .regular
        revealColor = color("revealColor", .white)
        revealThickness = number("revealThickness", 3)
        revealLength = number("revealLength", 0.25)
        revealGap = number("revealGap", 4)
        revealHoverHeight = number("revealHoverHeight", 8)
        revealIdleOpacity = number("revealIdleOpacity", 0.35)
        dockTint = color("dockTint", .clear)
        dockBorder = paint("dockBorder", .standard)
        dockBorderColor = color("dockBorderColor", .white.opacity(0.4))
        dockBorderWidth = number("dockBorderWidth", 1)
        dockShadow = number("dockShadow", 0)
        dockIndicator = paint("dockIndicator", .standard)
        dockIndicatorColor = color("dockIndicatorColor", .white)
        notchFill = paint("notchFill", .standard)
        notchFillColor = color("notchFillColor", Color(red: 0.1, green: 0.1, blue: 0.16))
        notchBorder = paint("notchBorder", .artwork)
        notchBorderColor = color("notchBorderColor", .white.opacity(0.5))
        notchBorderWidth = number("notchBorderWidth", 1)
        notchGlow = number("notchGlow", 0.3)
        notchShadow = number("notchShadow", 0.5)
        notchText = paint("notchText", .standard)
        notchTextColor = color("notchTextColor", .white)
        notchBars = paint("notchBars", .artwork)
        notchBarsColor = color("notchBarsColor", .white)
        windowTint = color("windowTint", .clear)
        windowRadius = number("windowRadius", 12)
        windowBorder = paint("windowBorder", .off)
        windowBorderColor = color("windowBorderColor", .white.opacity(0.4))
        windowBorderWidth = number("windowBorderWidth", 1)
        windowSelection = Selection(rawValue: d.string(forKey: Self.key("windowSelection")) ?? "") ?? .soft
    }

    /// The colour a paint setting gives, or nil for Default and Off (the caller decides those).
    func resolve(_ paint: Paint, custom: Color, artwork: Color? = nil) -> Color? {
        switch paint {
        case .standard, .off: return nil
        case .accent: return SwitchPreferences.shared.accent.color
        case .artwork: return artwork
        case .custom: return custom
        }
    }

    /// Everything back to the built-in look.
    func reset() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let fresh = StylePreferences()
        glass = fresh.glass
        revealColor = fresh.revealColor; revealThickness = fresh.revealThickness; revealLength = fresh.revealLength; revealGap = fresh.revealGap; revealHoverHeight = fresh.revealHoverHeight; revealIdleOpacity = fresh.revealIdleOpacity
        dockTint = fresh.dockTint; dockBorder = fresh.dockBorder; dockBorderColor = fresh.dockBorderColor
        dockBorderWidth = fresh.dockBorderWidth; dockShadow = fresh.dockShadow
        dockIndicator = fresh.dockIndicator; dockIndicatorColor = fresh.dockIndicatorColor
        notchFill = fresh.notchFill; notchFillColor = fresh.notchFillColor; notchBorder = fresh.notchBorder
        notchBorderColor = fresh.notchBorderColor; notchBorderWidth = fresh.notchBorderWidth
        notchGlow = fresh.notchGlow; notchShadow = fresh.notchShadow
        notchText = fresh.notchText; notchTextColor = fresh.notchTextColor
        notchBars = fresh.notchBars; notchBarsColor = fresh.notchBarsColor
        windowTint = fresh.windowTint; windowRadius = fresh.windowRadius; windowBorder = fresh.windowBorder
        windowBorderColor = fresh.windowBorderColor; windowBorderWidth = fresh.windowBorderWidth
        windowSelection = fresh.windowSelection
    }

    // MARK: Storage

    private static let prefix = "switch.style."
    private static func key(_ name: String) -> String { prefix + name }

    private func save(_ value: Any, _ name: String) { UserDefaults.standard.set(value, forKey: Self.key(name)) }
    private func save(_ color: Color, _ name: String) { save(Self.encode(color), name) }

    nonisolated static func encode(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "%.4f %.4f %.4f %.4f", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    nonisolated static func decode(_ text: String) -> Color? {
        let parts = text.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return Color(.sRGB, red: parts[0], green: parts[1], blue: parts[2], opacity: parts[3])
    }

    #if DEBUG
    /// Round-trips colours through storage; returns failures.
    nonisolated static func selfCheck() -> [String] {
        var failures: [String] = []
        for (r, g, b, a) in [(1.0, 0.0, 0.0, 1.0), (0.2, 0.4, 0.6, 0.5), (0, 0, 0, 0)] {
            let text = encode(Color(.sRGB, red: r, green: g, blue: b, opacity: a))
            guard let back = decode(text), encode(back) == text else { failures.append("colour round-trip \(text)"); continue }
        }
        if decode("1 2") != nil { failures.append("short string decoded") }
        return failures
    }
    #endif
}
