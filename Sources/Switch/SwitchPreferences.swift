import AppKit
import SwiftUI
import Combine

@MainActor
final class SwitchPreferences: ObservableObject {
    static let shared = SwitchPreferences()
    nonisolated static let defaultThumbnailHeight = 130.0
    nonisolated static let defaultAppIconSize = 32.0
    nonisolated static let defaultGridColumns = 4
    nonisolated static let defaultMaxListRows = 8
    nonisolated static let defaultPickerActivationDelay = 130.0
    nonisolated static let compactThumbnailHeight = 72.0

    enum AccentChoice: String, CaseIterable, Identifiable {
        case system, rose, blue, mint, peach, lavender, monochrome
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .rose: return "Rose"
            case .blue: return "Blue"
            case .mint: return "Mint"
            case .peach: return "Peach"
            case .lavender: return "Lavender"
            case .monochrome: return "Mono"
            }
        }
        var color: Color {
            switch self {
            case .system: return Color.accentColor
            case .rose: return Color(red: 0.741, green: 0.514, blue: 0.467)
            case .blue: return Color(red: 0.40, green: 0.62, blue: 0.92)
            case .mint: return Color(red: 0.42, green: 0.80, blue: 0.69)
            case .peach: return Color(red: 0.98, green: 0.69, blue: 0.49)
            case .lavender: return Color(red: 0.66, green: 0.58, blue: 0.86)
            case .monochrome: return Color(white: 0.86)
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    enum PickerDisplay: String, CaseIterable, Identifiable {
        case mouse, active, primary
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mouse: return "Mouse"
            case .active: return "Active"
            case .primary: return "Primary"
            }
        }
    }

    enum BackgroundBlur: String, CaseIterable, Identifiable {
        case light, medium, heavy, glass
        var id: String { rawValue }
        var label: String {
            switch self {
            case .light: return "Light"
            case .medium: return "Medium"
            case .heavy: return "Heavy"
            case .glass: return "Liquid Glass"
            }
        }
        /// Liquid Glass needs macOS 26; older systems only offer the materials.
        static var available: [BackgroundBlur] {
            if #available(macOS 26.0, *) { return allCases }
            return allCases.filter { $0 != .glass }
        }
        // Materials double as the pre-Tahoe fallback when .glass was stored.
        var material: Material {
            switch self {
            case .light, .glass: return .ultraThinMaterial
            case .medium: return .regularMaterial
            case .heavy: return .ultraThickMaterial
            }
        }
        var nsMaterial: NSVisualEffectView.Material {
            switch self {
            case .light, .glass: return .hudWindow
            case .medium: return .popover
            case .heavy: return .underWindowBackground
            }
        }
    }

    @Published var accent: AccentChoice {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: accentKey) }
    }

    @Published var backgroundBlur: BackgroundBlur {
        didSet { UserDefaults.standard.set(backgroundBlur.rawValue, forKey: backgroundBlurKey) }
    }

    @Published var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey) }
    }

    @Published var moveCursorToWindow: Bool {
        didSet { UserDefaults.standard.set(moveCursorToWindow, forKey: SwitchPreferences.moveCursorToWindowKey) }
    }

    @Published var showTitleFirst: Bool {
        didSet { UserDefaults.standard.set(showTitleFirst, forKey: showTitleFirstKey) }
    }

    @Published var showCrossSpace: Bool {
        didSet { UserDefaults.standard.set(showCrossSpace, forKey: SwitchPreferences.crossSpaceKey) }
    }

    @Published var stickyMode: Bool {
        didSet { UserDefaults.standard.set(stickyMode, forKey: SwitchPreferences.stickyModeKey) }
    }

    @Published var disableMouse: Bool {
        didSet { UserDefaults.standard.set(disableMouse, forKey: SwitchPreferences.disableMouseKey) }
    }

    @Published var disableAnimations: Bool {
        didSet { UserDefaults.standard.set(disableAnimations, forKey: disableAnimationsKey) }
    }

    /// Multiplier on every picker animation: 2 = twice as fast, 0.5 = half speed.
    @Published var animationSpeed: Double {
        didSet { UserDefaults.standard.set(animationSpeed, forKey: animationSpeedKey) }
    }
    static let animationSpeedRange: ClosedRange<Double> = 0.25...10
    /// Settings presets; 0 = Off (no animation).
    static let animationSpeedPresets: [Double] = [0, 1, 1.5, 2, 3, 5, 10]

    @Published var verticalList: Bool {
        didSet { UserDefaults.standard.set(verticalList, forKey: SwitchPreferences.verticalListKey) }
    }

    @Published var blacklist: Set<String> {
        didSet { UserDefaults.standard.set(Array(blacklist), forKey: SwitchPreferences.blacklistKey) }
    }

    @Published var titleExclusions: [String] {
        didSet { UserDefaults.standard.set(titleExclusions, forKey: SwitchPreferences.titleExclusionsKey) }
    }

    @Published var mruMixSpaces: Bool {
        didSet { UserDefaults.standard.set(mruMixSpaces, forKey: mruMixSpacesKey) }
    }

    @Published var staticOrder: Bool {
        didSet { UserDefaults.standard.set(staticOrder, forKey: SwitchPreferences.staticOrderKey) }
    }

    @Published var appOrder: [String] {
        didSet { UserDefaults.standard.set(appOrder, forKey: SwitchPreferences.appOrderKey) }
    }

    @Published var includeWindowlessApps: Bool {
        didSet { UserDefaults.standard.set(includeWindowlessApps, forKey: SwitchPreferences.includeWindowlessKey) }
    }

    @Published var hideMenuBarIcon: Bool {
        didSet { UserDefaults.standard.set(hideMenuBarIcon, forKey: SwitchPreferences.hideMenuBarIconKey) }
    }

    @Published var showThumbnails: Bool {
        didSet { UserDefaults.standard.set(showThumbnails, forKey: SwitchPreferences.showThumbnailsKey) }
    }

    @Published var showStoplights: Bool {
        didSet { UserDefaults.standard.set(showStoplights, forKey: SwitchPreferences.showStoplightsKey) }
    }

    @Published var verticalShowStoplights: Bool {
        didSet { UserDefaults.standard.set(verticalShowStoplights, forKey: SwitchPreferences.verticalShowStoplightsKey) }
    }

    @Published var verticalShowPreview: Bool {
        didSet { UserDefaults.standard.set(verticalShowPreview, forKey: SwitchPreferences.verticalShowPreviewKey) }
    }

    @Published var verticalShowHeader: Bool {
        didSet { UserDefaults.standard.set(verticalShowHeader, forKey: SwitchPreferences.verticalShowHeaderKey) }
    }

    @Published var showDockBadges: Bool {
        didSet { UserDefaults.standard.set(showDockBadges, forKey: SwitchPreferences.showDockBadgesKey) }
    }

    @Published var dockPreviews: Bool {
        didSet { UserDefaults.standard.set(dockPreviews, forKey: SwitchPreferences.dockPreviewsKey) }
    }

    /// Show win-tab's card over every hovered Dock icon, covering the Dock's own name label.
    @Published var dockReplaceLabels: Bool {
        didSet { UserDefaults.standard.set(dockReplaceLabels, forKey: SwitchPreferences.dockReplaceLabelsKey) }
    }

    @Published var dockPreviewDelay: Double {
        didSet { UserDefaults.standard.set(dockPreviewDelay, forKey: SwitchPreferences.dockPreviewDelayKey) }
    }
    static let dockPreviewDelayRange: ClosedRange<Double> = 0...1

    enum DockThumbSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @Published var dockThumbSize: DockThumbSize {
        didSet { UserDefaults.standard.set(dockThumbSize.rawValue, forKey: SwitchPreferences.dockThumbSizeKey) }
    }

    @Published var customDockEnabled: Bool {
        didSet { UserDefaults.standard.set(customDockEnabled, forKey: Self.customDockEnabledKey) }
    }
    @Published var customDockEdge: ScreenEdge {
        didSet { UserDefaults.standard.set(customDockEdge.rawValue, forKey: Self.customDockEdgeKey) }
    }
    /// Position along the edge, 0 = start (left/top), 1 = end.
    @Published var customDockOffset: Double {
        didSet { UserDefaults.standard.set(customDockOffset, forKey: Self.customDockOffsetKey) }
    }
    @Published var customDockIconSize: Double {
        didSet { UserDefaults.standard.set(customDockIconSize, forKey: Self.customDockIconSizeKey) }
    }
    @Published var customDockMagnifiedSize: Double {
        didSet { UserDefaults.standard.set(customDockMagnifiedSize, forKey: Self.customDockMagnifiedSizeKey) }
    }
    @Published var customDockHideSystemDock: Bool {
        didSet { UserDefaults.standard.set(customDockHideSystemDock, forKey: Self.customDockHideSystemDockKey) }
    }
    /// One Dock per display instead of only the main one.
    @Published var customDockAllDisplays: Bool {
        didSet { UserDefaults.standard.set(customDockAllDisplays, forKey: Self.customDockAllDisplaysKey) }
    }
    /// Your own arrangement (groups, folders, widgets…) instead of mirroring Apple's Dock.
    @Published var customDockUseOwnItems: Bool {
        didSet { UserDefaults.standard.set(customDockUseOwnItems, forKey: Self.customDockUseOwnItemsKey) }
    }
    @Published var customDockEntries: [DockEntry] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(customDockEntries), forKey: Self.customDockEntriesKey) }
    }
    /// Dynamic Island on the notch.
    @Published var notchEnabled: Bool {
        didSet { UserDefaults.standard.set(notchEnabled, forKey: Self.notchEnabledKey) }
    }
    /// Also a pill on displays without a notch.
    /// Which displays get an island.
    /// Which display alerts (notifications, battery) show on.
    enum AlertDisplay: String, CaseIterable, Identifiable {
        case main, pointer, all, chosen
        var id: String { rawValue }
        var label: String {
            switch self {
            case .main: return "Main display"
            case .pointer: return "Under the pointer"
            case .all: return "All at once"
            case .chosen: return "One display…"
            }
        }
    }
    @Published var alertDisplay: AlertDisplay {
        didSet { UserDefaults.standard.set(alertDisplay.rawValue, forKey: "switch.alerts.display") }
    }
    @Published var alertScreenName: String {
        didSet { UserDefaults.standard.set(alertScreenName, forKey: "switch.alerts.screenName") }
    }

    /// The displays an alert goes to right now.
    @MainActor var alertScreens: [NSScreen] {
        let screens = NSScreen.screens
        let main = screens.first.map { [$0] } ?? []
        switch alertDisplay {
        case .all: return screens
        case .main: return main
        case .pointer:
            let mouse = NSEvent.mouseLocation
            return screens.first { NSMouseInRect(mouse, $0.frame, false) }.map { [$0] } ?? main
        case .chosen:
            return screens.first { $0.localizedName == alertScreenName }.map { [$0] } ?? main
        }
    }

    enum NotchDisplays: String, CaseIterable, Identifiable {
        case notched, all, main, mouse, chosen
        var id: String { rawValue }
        var label: String {
            switch self {
            case .notched: return "With a notch"
            case .all: return "Every display"
            case .main: return "Menu-bar display"
            case .mouse: return "Under the pointer"
            case .chosen: return "One display…"
            }
        }
    }
    @Published var notchDisplays: NotchDisplays {
        didSet { UserDefaults.standard.set(notchDisplays.rawValue, forKey: Self.notchDisplaysKey) }
    }
    /// Display name for `.chosen`.
    @Published var notchScreenName: String {
        didSet { UserDefaults.standard.set(notchScreenName, forKey: Self.notchScreenNameKey) }
    }

    /// What hovering an icon on win-tab's Dock does.
    enum DockHoverEffect: String, CaseIterable, Identifiable {
        case magnify, lift, glow, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .magnify: return "Magnify"
            case .lift: return "Lift"
            case .glow: return "Glow"
            case .none: return "None"
            }
        }
    }
    /// How icons move to follow the pointer.
    enum DockHoverMotion: String, CaseIterable, Identifiable {
        case instant, smooth, spring, bouncy
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    @Published var customDockHoverEffect: DockHoverEffect {
        didSet { UserDefaults.standard.set(customDockHoverEffect.rawValue, forKey: Self.customDockHoverEffectKey) }
    }
    @Published var customDockHoverMotion: DockHoverMotion {
        didSet { UserDefaults.standard.set(customDockHoverMotion.rawValue, forKey: Self.customDockHoverMotionKey) }
    }
    /// How many icons either side the magnification reaches.
    @Published var customDockSpread: Double {
        didSet { UserDefaults.standard.set(customDockSpread, forKey: Self.customDockSpreadKey) }
    }
    @Published var customDockSpacing: Double {
        didSet { UserDefaults.standard.set(customDockSpacing, forKey: Self.customDockSpacingKey) }
    }
    @Published var customDockPadding: Double {
        didSet { UserDefaults.standard.set(customDockPadding, forKey: Self.customDockPaddingKey) }
    }
    /// Gap between the Dock and the screen edge.
    @Published var customDockMargin: Double {
        didSet { UserDefaults.standard.set(customDockMargin, forKey: Self.customDockMarginKey) }
    }
    /// Icons hop when clicked, like Apple's launch bounce.
    @Published var customDockClickBounce: Bool {
        didSet { UserDefaults.standard.set(customDockClickBounce, forKey: Self.customDockClickBounceKey) }
    }
    /// Where the Dock sits on one display; displays without one use the default edge and offset.
    struct DockPlacement: Codable, Equatable {
        var edge: String
        var offset: Double
    }
    /// Per display (by name), so e.g. the main display has the Dock at the bottom and another on the right.
    @Published var customDockPlacements: [String: DockPlacement] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(customDockPlacements), forKey: Self.customDockPlacementsKey) }
    }
    func dockPlacement(for screen: NSScreen) -> (edge: ScreenEdge, offset: Double) {
        guard let p = customDockPlacements[screen.localizedName], let edge = ScreenEdge(rawValue: p.edge) else {
            return (customDockEdge, customDockOffset)
        }
        return (edge, p.offset)
    }
    func setDockPlacement(_ edge: ScreenEdge, offset: Double, for screen: NSScreen) {
        var all = customDockPlacements
        all[screen.localizedName] = DockPlacement(edge: edge.rawValue, offset: min(max(offset, 0), 1))
        customDockPlacements = all
    }

    /// win-tab's Dock slides out of sight until the pointer reaches its screen edge.
    @Published var customDockAutoHide: Bool {
        didSet { UserDefaults.standard.set(customDockAutoHide, forKey: Self.customDockAutoHideKey) }
    }
    @Published var customDockAutoHideDelay: Double {
        didSet { UserDefaults.standard.set(customDockAutoHideDelay, forKey: Self.customDockAutoHideDelayKey) }
    }
    static let customDockAutoHideDelayRange: ClosedRange<Double> = 0...2
    enum DockBarStyle: String, CaseIterable, Identifiable {
        case glass, blur, dark, clear
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    @Published var customDockBarStyle: DockBarStyle {
        didSet { UserDefaults.standard.set(customDockBarStyle.rawValue, forKey: Self.customDockBarStyleKey) }
    }
    @Published var customDockCornerRadius: Double {
        didSet { UserDefaults.standard.set(customDockCornerRadius, forKey: Self.customDockCornerRadiusKey) }
    }
    static let customDockCornerRadiusRange: ClosedRange<Double> = 0...32
    enum DockIndicator: String, CaseIterable, Identifiable {
        case dot, line, none
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    @Published var customDockIndicator: DockIndicator {
        didSet { UserDefaults.standard.set(customDockIndicator.rawValue, forKey: Self.customDockIndicatorKey) }
    }
    @Published var customDockShowBadges: Bool {
        didSet { UserDefaults.standard.set(customDockShowBadges, forKey: Self.customDockShowBadgesKey) }
    }

    /// When the drag grip shows.
    enum DockGripMode: String, CaseIterable, Identifiable {
        case edge, option, always, never
        var id: String { rawValue }
        var label: String {
            switch self {
            case .edge: return "At the start"
            case .option: return "Hold ⌥"
            case .always: return "Always"
            case .never: return "Never"
            }
        }
    }
    @Published var customDockGripMode: DockGripMode {
        didSet { UserDefaults.standard.set(customDockGripMode.rawValue, forKey: Self.customDockGripModeKey) }
    }
    enum DockHideStyle: String, CaseIterable, Identifiable {
        case slide, fade, slideFade
        var id: String { rawValue }
        var label: String {
            switch self {
            case .slide: return "Slide"
            case .fade: return "Fade"
            case .slideFade: return "Slide & Fade"
            }
        }
    }
    @Published var customDockHideStyle: DockHideStyle {
        didSet { UserDefaults.standard.set(customDockHideStyle.rawValue, forKey: Self.customDockHideStyleKey) }
    }
    /// Seconds a hide or show takes.
    @Published var customDockHideDuration: Double {
        didSet { UserDefaults.standard.set(customDockHideDuration, forKey: Self.customDockHideDurationKey) }
    }
    static let customDockHideDurationRange: ClosedRange<Double> = 0.1...0.8
    /// The thin bar left at the screen edge while the Dock is hidden.
    enum DockRevealBar: String, CaseIterable, Identifiable {
        case auto, white, black, glass, custom, none
        var id: String { rawValue }
        var label: String { self == .glass ? "Glass" : rawValue.capitalized }
    }
    @Published var customDockRevealBar: DockRevealBar {
        didSet { UserDefaults.standard.set(customDockRevealBar.rawValue, forKey: Self.customDockRevealBarKey) }
    }

    /// A Trash at the end of win-tab's Dock.
    @Published var customDockShowTrash: Bool {
        didSet { UserDefaults.standard.set(customDockShowTrash, forKey: "switch.customDock.showTrash") }
    }

    /// Grip at the start of the Dock for dragging it along or to another edge.
    @Published var customDockShowHandle: Bool {
        didSet { UserDefaults.standard.set(customDockShowHandle, forKey: Self.customDockShowHandleKey) }
    }
    /// Size a hovered icon grows to with Lift and Glow, and widgets with any effect.
    @Published var customDockHoverZoom: Double {
        didSet { UserDefaults.standard.set(customDockHoverZoom, forKey: Self.customDockHoverZoomKey) }
    }
    /// Extra room on each side of a widget.
    @Published var customDockWidgetGap: Double {
        didSet { UserDefaults.standard.set(customDockWidgetGap, forKey: Self.customDockWidgetGapKey) }
    }
    enum DockWidgetStyle: String, CaseIterable, Identifiable {
        case dark, light, glass
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    @Published var customDockWidgetStyle: DockWidgetStyle {
        didSet { UserDefaults.standard.set(customDockWidgetStyle.rawValue, forKey: Self.customDockWidgetStyleKey) }
    }
    static let customDockHoverZoomRange: ClosedRange<Double> = 1...1.5
    static let customDockWidgetGapRange: ClosedRange<Double> = 0...24
    static let customDockSpreadRange: ClosedRange<Double> = 1.5...5
    static let customDockSpacingRange: ClosedRange<Double> = 0...24
    static let customDockPaddingRange: ClosedRange<Double> = 2...20
    static let customDockMarginRange: ClosedRange<Double> = 0...40
    @Published var notchClipboardHistory: Bool {
        didSet { UserDefaults.standard.set(notchClipboardHistory, forKey: Self.notchClipboardHistoryKey) }
    }
    /// How long clipboard history is kept (pinned clips stay until unpinned).
    enum ClipboardRetention: String, CaseIterable, Identifiable {
        case oneDay, twoDays, oneWeek
        var id: String { rawValue }
        var label: String {
            switch self {
            case .oneDay: return "1 day"
            case .twoDays: return "2 days"
            case .oneWeek: return "1 week"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .oneDay: return 86_400
            case .twoDays: return 2 * 86_400
            case .oneWeek: return 7 * 86_400
            }
        }
    }
    @Published var notchClipboardRetention: ClipboardRetention {
        didSet { UserDefaults.standard.set(notchClipboardRetention.rawValue, forKey: Self.notchClipboardRetentionKey) }
    }
    /// Pause on the notch before it opens.
    @Published var notchHoverDelay: Double {
        didSet { UserDefaults.standard.set(notchHoverDelay, forKey: Self.notchHoverDelayKey) }
    }
    /// Open with a click; hovering only swells the island.
    @Published var notchOpenOnClick: Bool {
        didSet { UserDefaults.standard.set(notchOpenOnClick, forKey: Self.notchOpenOnClickKey) }
    }
    /// How long the pointer can be away before the island closes.
    @Published var notchCloseDelay: Double {
        didSet { UserDefaults.standard.set(notchCloseDelay, forKey: Self.notchCloseDelayKey) }
    }
    enum NotchSize: String, CaseIterable, Identifiable {
        case compact, regular, large
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var content: CGSize {
            switch self {
            case .compact: return CGSize(width: 520, height: 146)
            case .regular: return CGSize(width: 580, height: 158)
            case .large: return CGSize(width: 660, height: 184)
            }
        }
    }
    @Published var notchSize: NotchSize {
        didSet { UserDefaults.standard.set(notchSize.rawValue, forKey: Self.notchSizeKey) }
    }
    enum NotchAnimation: String, CaseIterable, Identifiable {
        case island, smooth, snappy, bouncy
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    @Published var notchAnimation: NotchAnimation {
        didSet { UserDefaults.standard.set(notchAnimation.rawValue, forKey: Self.notchAnimationKey) }
    }
    @Published var notchAnimationSpeed: Double {
        didSet { UserDefaults.standard.set(notchAnimationSpeed, forKey: Self.notchAnimationSpeedKey) }
    }
    /// Song artwork or timer beside the closed notch.
    @Published var notchShowActivity: Bool {
        didSet { UserDefaults.standard.set(notchShowActivity, forKey: Self.notchShowActivityKey) }
    }
    @Published var notchShowBattery: Bool {
        didSet { UserDefaults.standard.set(notchShowBattery, forKey: Self.notchShowBatteryKey) }
    }
    @Published var notchShowKeepAwake: Bool {
        didSet { UserDefaults.standard.set(notchShowKeepAwake, forKey: Self.notchShowKeepAwakeKey) }
    }
    /// Tabs shown besides Home.
    /// Where the open island's tabs sit.
    enum NotchTabBar: String, CaseIterable, Identifiable {
        case below, top
        var id: String { rawValue }
        var label: String { self == .below ? "Below the island" : "In the top row" }
    }
    @Published var notchTabBar: NotchTabBar {
        didSet { UserDefaults.standard.set(notchTabBar.rawValue, forKey: Self.notchTabBarKey) }
    }
    @Published var notchTabs: Set<String> {
        didSet { UserDefaults.standard.set(Array(notchTabs), forKey: Self.notchTabsKey) }
    }
    /// Items beside the closed notch, in order from left to right on each side: "artwork" (song
    /// artwork or timer icon), "bars" (equalizer or countdown), "time", "date", "wifi", "battery".
    @Published var notchLeftItems: [String] {
        didSet { UserDefaults.standard.set(notchLeftItems, forKey: Self.notchLeftItemsKey) }
    }
    @Published var notchRightItems: [String] {
        didSet { UserDefaults.standard.set(notchRightItems, forKey: Self.notchRightItemsKey) }
    }
    static let notchStatusKeys: Set<String> = ["time", "date", "wifi", "battery"]
    static let notchItemKeys = ["artwork", "time", "date", "wifi", "battery", "bars"]

    /// The status items placed on either side.
    var notchStatusItems: Set<String> {
        Set(notchLeftItems + notchRightItems).intersection(Self.notchStatusKeys)
    }

    /// Status items stay beside the notch while a song or timer shows too (else they give way).
    @Published var notchStatusWithActivity: Bool {
        didSet { UserDefaults.standard.set(notchStatusWithActivity, forKey: Self.notchStatusWithActivityKey) }
    }

    /// A light trackpad tap when the island opens.
    /// The island steps aside while an app is full screen on its display.
    @Published var notchHideInFullScreen: Bool {
        didSet { UserDefaults.standard.set(notchHideInFullScreen, forKey: Self.notchHideInFullScreenKey) }
    }
    @Published var notchHaptics: Bool {
        didSet { UserDefaults.standard.set(notchHaptics, forKey: Self.notchHapticsKey) }
    }
    static let notchHoverDelayRange: ClosedRange<Double> = 0...0.6
    static let notchCloseDelayRange: ClosedRange<Double> = 0.1...1.5
    static let notchAnimationSpeedRange: ClosedRange<Double> = 0.5...2
    static let customDockIconRange: ClosedRange<Double> = 24...96
    static let customDockMagnifiedRange: ClosedRange<Double> = 32...128

    @Published var dockClickToHide: Bool {
        didSet { UserDefaults.standard.set(dockClickToHide, forKey: SwitchPreferences.dockClickToHideKey) }
    }

    @Published var dockScrollCyclesWindows: Bool {
        didSet { UserDefaults.standard.set(dockScrollCyclesWindows, forKey: SwitchPreferences.dockScrollCyclesWindowsKey) }
    }

    @Published var showHintStrip: Bool {
        didSet { UserDefaults.standard.set(showHintStrip, forKey: SwitchPreferences.showHintStripKey) }
    }

    @Published var showWindowCount: Bool {
        didSet { UserDefaults.standard.set(showWindowCount, forKey: SwitchPreferences.showWindowCountKey) }
    }

    @Published var currentDisplayOnly: Bool {
        didSet { UserDefaults.standard.set(currentDisplayOnly, forKey: SwitchPreferences.currentDisplayOnlyKey) }
    }

    @Published var typeToFilter: Bool {
        didSet {
            UserDefaults.standard.set(typeToFilter, forKey: SwitchPreferences.typeToFilterKey)
            if typeToFilter && vimNavigation { vimNavigation = false }
        }
    }

    @Published var vimNavigation: Bool {
        didSet {
            UserDefaults.standard.set(vimNavigation, forKey: SwitchPreferences.vimNavigationKey)
            if vimNavigation && typeToFilter { typeToFilter = false }
        }
    }

    @Published var thumbnailHeight: Double {
        didSet { UserDefaults.standard.set(thumbnailHeight, forKey: SwitchPreferences.thumbnailHeightKey) }
    }

    @Published var appIconSize: Double {
        didSet { UserDefaults.standard.set(appIconSize, forKey: SwitchPreferences.appIconSizeKey) }
    }

    @Published var gridColumns: Int {
        didSet { UserDefaults.standard.set(gridColumns, forKey: SwitchPreferences.gridColumnsKey) }
    }

    @Published var maxListRows: Int {
        didSet { UserDefaults.standard.set(maxListRows, forKey: SwitchPreferences.maxListRowsKey) }
    }

    @Published var pinnedBundleIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(pinnedBundleIDs), forKey: SwitchPreferences.pinnedBundleIDsKey) }
    }

    @Published var pickerActivationDelay: Double {
        didSet { UserDefaults.standard.set(pickerActivationDelay, forKey: SwitchPreferences.pickerActivationDelayKey) }
    }

    @Published var shiftTapReverses: Bool {
        didSet { UserDefaults.standard.set(shiftTapReverses, forKey: SwitchPreferences.shiftTapReversesKey) }
    }

    /// ⌘-Tab: apps without windows as small icons in one strip instead of full tiles.
    @Published var compactWindowlessApps: Bool {
        didSet { UserDefaults.standard.set(compactWindowlessApps, forKey: SwitchPreferences.compactWindowlessAppsKey) }
    }

    /// Window mode with compact windowless apps on: a strip of small icons in the grid, slim rows in the list.
    nonisolated static func compactsWindowless(mode: HotkeyManager.Mode) -> Bool {
        mode == .allWindows && ((UserDefaults.standard.object(forKey: compactWindowlessAppsKey) as? Bool) ?? true)
    }

    @Published var hideMinimizedWindows: Bool {
        didSet { UserDefaults.standard.set(hideMinimizedWindows, forKey: SwitchPreferences.hideMinimizedWindowsKey) }
    }

    @Published var showNumberKeyHints: Bool {
        didSet { UserDefaults.standard.set(showNumberKeyHints, forKey: SwitchPreferences.showNumberKeyHintsKey) }
    }

    @Published var pickerDisplay: PickerDisplay {
        didSet { UserDefaults.standard.set(pickerDisplay.rawValue, forKey: SwitchPreferences.pickerDisplayKey) }
    }

    private let accentKey = "switch.accent"
    private let backgroundBlurKey = "switch.backgroundBlur"
    private let appearanceKey = "switch.appearance"
    nonisolated static let moveCursorToWindowKey = "switch.moveCursorToWindow"
    private let showTitleFirstKey = "switch.showTitleFirst"
    nonisolated static let crossSpaceKey = "switch.showCrossSpace"
    nonisolated static let stickyModeKey = "switch.stickyMode"
    nonisolated static let disableMouseKey = "switch.disableMouse"
    private let disableAnimationsKey = "switch.disableAnimations"
    private let animationSpeedKey = "switch.animationSpeed"
    nonisolated static let verticalListKey = "switch.verticalList"
    nonisolated static let blacklistKey = "switch.blacklist"
    nonisolated static let titleExclusionsKey = "switch.titleExclusions"
    private let mruMixSpacesKey = "switch.mruMixSpaces"
    nonisolated static let staticOrderKey = "switch.staticOrder"
    nonisolated static let appOrderKey = "switch.appOrder"
    nonisolated static let includeWindowlessKey = "switch.includeWindowlessApps"
    nonisolated static let hideMenuBarIconKey = "switch.hideMenuBarIcon"
    nonisolated static let showThumbnailsKey = "switch.showThumbnails"
    nonisolated static let showStoplightsKey = "switch.showStoplights"
    nonisolated static let verticalShowStoplightsKey = "switch.verticalShowStoplights"
    nonisolated static let verticalShowPreviewKey = "switch.verticalShowPreview"
    nonisolated static let verticalShowHeaderKey = "switch.verticalShowHeader"
    nonisolated static let showHintStripKey = "switch.showHintStrip"
    nonisolated static let showDockBadgesKey = "switch.showDockBadges"
    nonisolated static let dockPreviewsKey = "switch.dockPreviews"
    nonisolated static let dockClickToHideKey = "switch.dockClickToHide"
    nonisolated static let dockReplaceLabelsKey = "switch.dockReplaceLabels"
    nonisolated static let customDockEnabledKey = "switch.customDock.enabled"
    nonisolated static let customDockEdgeKey = "switch.customDock.edge"
    nonisolated static let customDockOffsetKey = "switch.customDock.offset"
    nonisolated static let customDockIconSizeKey = "switch.customDock.iconSize"
    nonisolated static let customDockMagnificationKey = "switch.customDock.magnification"
    nonisolated static let customDockMagnifiedSizeKey = "switch.customDock.magnifiedSize"
    nonisolated static let customDockHideSystemDockKey = "switch.customDock.hideSystemDock"
    nonisolated static let customDockAllDisplaysKey = "switch.customDock.allDisplays"
    nonisolated static let customDockUseOwnItemsKey = "switch.customDock.useOwnItems"
    nonisolated static let customDockEntriesKey = "switch.customDock.entries"
    nonisolated static let compactWindowlessAppsKey = "switch.compactWindowlessApps"
    nonisolated static let notchEnabledKey = "switch.notch.enabled"
    nonisolated static let notchOnAllDisplaysKey = "switch.notch.allDisplays"
    nonisolated static let notchDisplaysKey = "switch.notch.displays"
    nonisolated static let notchScreenNameKey = "switch.notch.screenName"
    nonisolated static let customDockHoverEffectKey = "switch.customDock.hoverEffect"
    nonisolated static let customDockHoverMotionKey = "switch.customDock.hoverMotion"
    nonisolated static let customDockSpreadKey = "switch.customDock.spread"
    nonisolated static let customDockSpacingKey = "switch.customDock.spacing"
    nonisolated static let customDockPaddingKey = "switch.customDock.padding"
    nonisolated static let customDockMarginKey = "switch.customDock.margin"
    nonisolated static let customDockClickBounceKey = "switch.customDock.clickBounce"
    nonisolated static let customDockShowHandleKey = "switch.customDock.showHandle"
    nonisolated static let customDockGripModeKey = "switch.customDock.gripMode"
    nonisolated static let customDockHideStyleKey = "switch.customDock.hideStyle"
    nonisolated static let customDockHideDurationKey = "switch.customDock.hideDuration"
    nonisolated static let customDockRevealBarKey = "switch.customDock.revealBar"
    nonisolated static let customDockPlacementsKey = "switch.customDock.placements"
    nonisolated static let customDockAutoHideKey = "switch.customDock.autoHide"
    nonisolated static let customDockAutoHideDelayKey = "switch.customDock.autoHideDelay"
    nonisolated static let customDockBarStyleKey = "switch.customDock.barStyle"
    nonisolated static let customDockCornerRadiusKey = "switch.customDock.cornerRadius"
    nonisolated static let customDockIndicatorKey = "switch.customDock.indicator"
    nonisolated static let customDockShowBadgesKey = "switch.customDock.showBadges"
    nonisolated static let customDockHoverZoomKey = "switch.customDock.hoverZoom"
    nonisolated static let customDockWidgetGapKey = "switch.customDock.widgetGap"
    nonisolated static let customDockWidgetStyleKey = "switch.customDock.widgetStyle"
    nonisolated static let notchClipboardHistoryKey = "switch.notch.clipboardHistory"
    nonisolated static let notchClipboardRetentionKey = "switch.notch.clipboardRetention"
    nonisolated static let notchHoverDelayKey = "switch.notch.hoverDelay"
    nonisolated static let notchOpenOnClickKey = "switch.notch.openOnClick"
    nonisolated static let notchCloseDelayKey = "switch.notch.closeDelay"
    nonisolated static let notchSizeKey = "switch.notch.size"
    nonisolated static let notchAnimationKey = "switch.notch.animation"
    nonisolated static let notchAnimationSpeedKey = "switch.notch.animationSpeed"
    nonisolated static let notchShowActivityKey = "switch.notch.showActivity"
    nonisolated static let notchShowBatteryKey = "switch.notch.showBattery"
    nonisolated static let notchShowKeepAwakeKey = "switch.notch.showKeepAwake"
    nonisolated static let notchTabsKey = "switch.notch.tabs"
    nonisolated static let notchTabBarKey = "switch.notch.tabBar"
    nonisolated static let notchHapticsKey = "switch.notch.haptics"
    nonisolated static let notchHideInFullScreenKey = "switch.notch.hideInFullScreen"
    nonisolated static let notchStatusItemsKey = "switch.notch.statusItems"
    nonisolated static let notchLeftItemsKey = "switch.notch.leftItems"
    nonisolated static let notchRightItemsKey = "switch.notch.rightItems"
    nonisolated static let notchStatusWithActivityKey = "switch.notch.statusWithActivity"
    nonisolated static let dockPreviewDelayKey = "switch.dockPreviewDelay"
    nonisolated static let dockThumbSizeKey = "switch.dockThumbSize"
    nonisolated static let dockScrollCyclesWindowsKey = "switch.dockScrollCyclesWindows"
    nonisolated static let showWindowCountKey = "switch.showWindowCount"
    nonisolated static let currentDisplayOnlyKey = "switch.currentDisplayOnly"
    nonisolated static let typeToFilterKey = "switch.typeToFilter"
    nonisolated static let vimNavigationKey = "switch.vimNavigation"
    nonisolated static let thumbnailHeightKey = "switch.thumbnailHeight"
    nonisolated static let appIconSizeKey = "switch.appIconSize"
    nonisolated static let gridColumnsKey = "switch.gridColumns"
    nonisolated static let maxListRowsKey = "switch.maxListRows"
    nonisolated static let pinnedBundleIDsKey = "switch.pinnedBundleIDs"
    nonisolated static let pickerActivationDelayKey = "switch.pickerActivationDelay"
    nonisolated static let shiftTapReversesKey = "switch.shiftTapReverses"
    nonisolated static let hideMinimizedWindowsKey = "switch.hideMinimizedWindows"
    nonisolated static let showNumberKeyHintsKey = "switch.showNumberKeyHints"
    nonisolated static let pickerDisplayKey = "switch.pickerDisplay"

    private init() {
        accent = AccentChoice(rawValue: UserDefaults.standard.string(forKey: accentKey) ?? "") ?? .system
        appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system
        moveCursorToWindow = UserDefaults.standard.bool(forKey: SwitchPreferences.moveCursorToWindowKey)
        backgroundBlur = BackgroundBlur(rawValue: UserDefaults.standard.string(forKey: backgroundBlurKey) ?? "") ?? .light
        showTitleFirst = UserDefaults.standard.bool(forKey: showTitleFirstKey)
        showCrossSpace = (UserDefaults.standard.object(forKey: SwitchPreferences.crossSpaceKey) as? Bool) ?? true
        stickyMode = UserDefaults.standard.bool(forKey: SwitchPreferences.stickyModeKey)
        disableMouse = UserDefaults.standard.bool(forKey: SwitchPreferences.disableMouseKey)
        disableAnimations = UserDefaults.standard.bool(forKey: disableAnimationsKey)
        let storedSpeed = (UserDefaults.standard.object(forKey: animationSpeedKey) as? Double) ?? 1
        animationSpeed = min(max(storedSpeed, Self.animationSpeedRange.lowerBound), Self.animationSpeedRange.upperBound)
        verticalList = UserDefaults.standard.bool(forKey: SwitchPreferences.verticalListKey)
        blacklist = Set(UserDefaults.standard.stringArray(forKey: SwitchPreferences.blacklistKey) ?? [])
        titleExclusions = UserDefaults.standard.stringArray(forKey: SwitchPreferences.titleExclusionsKey) ?? []
        mruMixSpaces = (UserDefaults.standard.object(forKey: mruMixSpacesKey) as? Bool) ?? true
        staticOrder = UserDefaults.standard.bool(forKey: SwitchPreferences.staticOrderKey)
        appOrder = UserDefaults.standard.stringArray(forKey: SwitchPreferences.appOrderKey) ?? []
        includeWindowlessApps = UserDefaults.standard.bool(forKey: SwitchPreferences.includeWindowlessKey)
        hideMenuBarIcon = UserDefaults.standard.bool(forKey: SwitchPreferences.hideMenuBarIconKey)
        showThumbnails = (UserDefaults.standard.object(forKey: SwitchPreferences.showThumbnailsKey) as? Bool) ?? true
        showStoplights = (UserDefaults.standard.object(forKey: SwitchPreferences.showStoplightsKey) as? Bool) ?? true
        verticalShowStoplights = (UserDefaults.standard.object(forKey: SwitchPreferences.verticalShowStoplightsKey) as? Bool) ?? true
        verticalShowPreview = (UserDefaults.standard.object(forKey: SwitchPreferences.verticalShowPreviewKey) as? Bool) ?? true
        verticalShowHeader = (UserDefaults.standard.object(forKey: SwitchPreferences.verticalShowHeaderKey) as? Bool) ?? true
        showHintStrip = (UserDefaults.standard.object(forKey: SwitchPreferences.showHintStripKey) as? Bool) ?? true
        showDockBadges = (UserDefaults.standard.object(forKey: SwitchPreferences.showDockBadgesKey) as? Bool) ?? true
        dockPreviews = (UserDefaults.standard.object(forKey: SwitchPreferences.dockPreviewsKey) as? Bool) ?? true
        dockClickToHide = UserDefaults.standard.bool(forKey: SwitchPreferences.dockClickToHideKey)
        dockReplaceLabels = (UserDefaults.standard.object(forKey: SwitchPreferences.dockReplaceLabelsKey) as? Bool) ?? true
        let d = UserDefaults.standard
        customDockEnabled = d.bool(forKey: Self.customDockEnabledKey)
        customDockEdge = ScreenEdge(rawValue: d.string(forKey: Self.customDockEdgeKey) ?? "") ?? .bottom
        customDockOffset = min(max((d.object(forKey: Self.customDockOffsetKey) as? Double) ?? 0.5, 0), 1)
        customDockIconSize = min(max((d.object(forKey: Self.customDockIconSizeKey) as? Double) ?? 48, Self.customDockIconRange.lowerBound), Self.customDockIconRange.upperBound)
        customDockMagnifiedSize = min(max((d.object(forKey: Self.customDockMagnifiedSizeKey) as? Double) ?? 72, Self.customDockMagnifiedRange.lowerBound), Self.customDockMagnifiedRange.upperBound)
        customDockHideSystemDock = d.bool(forKey: Self.customDockHideSystemDockKey)
        customDockAllDisplays = d.bool(forKey: Self.customDockAllDisplaysKey)
        customDockUseOwnItems = d.bool(forKey: Self.customDockUseOwnItemsKey)
        customDockEntries = d.data(forKey: Self.customDockEntriesKey).flatMap { try? JSONDecoder().decode([DockEntry].self, from: $0) } ?? []
        compactWindowlessApps = (d.object(forKey: Self.compactWindowlessAppsKey) as? Bool) ?? true
        notchEnabled = (d.object(forKey: Self.notchEnabledKey) as? Bool) ?? true
        // The older on/off for other displays maps to "every display".
        notchDisplays = NotchDisplays(rawValue: d.string(forKey: Self.notchDisplaysKey) ?? "")
            ?? (d.bool(forKey: Self.notchOnAllDisplaysKey) ? .all : .notched)
        notchScreenName = d.string(forKey: Self.notchScreenNameKey) ?? ""
        customDockHoverEffect = DockHoverEffect(rawValue: d.string(forKey: Self.customDockHoverEffectKey) ?? "")
            ?? (((d.object(forKey: Self.customDockMagnificationKey) as? Bool) ?? true) ? .magnify : .none)
        customDockHoverMotion = DockHoverMotion(rawValue: d.string(forKey: Self.customDockHoverMotionKey) ?? "") ?? .smooth
        let clamp = { (key: String, fallback: Double, range: ClosedRange<Double>) in
            min(max((d.object(forKey: key) as? Double) ?? fallback, range.lowerBound), range.upperBound)
        }
        customDockSpread = clamp(Self.customDockSpreadKey, 2.5, Self.customDockSpreadRange)
        customDockSpacing = clamp(Self.customDockSpacingKey, 8, Self.customDockSpacingRange)
        customDockPadding = clamp(Self.customDockPaddingKey, 8, Self.customDockPaddingRange)
        customDockMargin = clamp(Self.customDockMarginKey, 6, Self.customDockMarginRange)
        customDockClickBounce = (d.object(forKey: Self.customDockClickBounceKey) as? Bool) ?? true
        customDockShowHandle = (d.object(forKey: Self.customDockShowHandleKey) as? Bool) ?? true
        customDockGripMode = DockGripMode(rawValue: d.string(forKey: Self.customDockGripModeKey) ?? "")
            ?? (((d.object(forKey: Self.customDockShowHandleKey) as? Bool) ?? true) ? .edge : .never)
        customDockHideStyle = DockHideStyle(rawValue: d.string(forKey: Self.customDockHideStyleKey) ?? "") ?? .slideFade
        customDockHideDuration = min(max((d.object(forKey: Self.customDockHideDurationKey) as? Double) ?? 0.28, 0.1), 0.8)
        customDockRevealBar = DockRevealBar(rawValue: d.string(forKey: Self.customDockRevealBarKey) ?? "") ?? .auto
        customDockShowTrash = d.object(forKey: "switch.customDock.showTrash") as? Bool ?? true
        alertDisplay = AlertDisplay(rawValue: d.string(forKey: "switch.alerts.display") ?? "") ?? .main
        alertScreenName = d.string(forKey: "switch.alerts.screenName") ?? ""
        customDockPlacements = d.data(forKey: Self.customDockPlacementsKey)
            .flatMap { try? JSONDecoder().decode([String: DockPlacement].self, from: $0) } ?? [:]
        customDockAutoHide = d.bool(forKey: Self.customDockAutoHideKey)
        customDockAutoHideDelay = clamp(Self.customDockAutoHideDelayKey, 0.4, Self.customDockAutoHideDelayRange)
        // The Dock used the picker's background before it had its own style.
        let pickerGlass = (d.string(forKey: "switch.backgroundBlur") ?? "") == "glass"
        customDockBarStyle = DockBarStyle(rawValue: d.string(forKey: Self.customDockBarStyleKey) ?? "") ?? (pickerGlass ? .glass : .blur)
        customDockCornerRadius = clamp(Self.customDockCornerRadiusKey, 16, Self.customDockCornerRadiusRange)
        customDockIndicator = DockIndicator(rawValue: d.string(forKey: Self.customDockIndicatorKey) ?? "") ?? .dot
        customDockShowBadges = (d.object(forKey: Self.customDockShowBadgesKey) as? Bool) ?? true
        customDockHoverZoom = clamp(Self.customDockHoverZoomKey, 1.12, Self.customDockHoverZoomRange)
        customDockWidgetGap = clamp(Self.customDockWidgetGapKey, 6, Self.customDockWidgetGapRange)
        customDockWidgetStyle = DockWidgetStyle(rawValue: d.string(forKey: Self.customDockWidgetStyleKey) ?? "") ?? .dark
        notchClipboardHistory = (d.object(forKey: Self.notchClipboardHistoryKey) as? Bool) ?? true
        notchClipboardRetention = ClipboardRetention(rawValue: d.string(forKey: Self.notchClipboardRetentionKey) ?? "") ?? .twoDays
        let clampN = { (key: String, fallback: Double, range: ClosedRange<Double>) in
            min(max((d.object(forKey: key) as? Double) ?? fallback, range.lowerBound), range.upperBound)
        }
        notchHoverDelay = clampN(Self.notchHoverDelayKey, 0.12, Self.notchHoverDelayRange)
        // Click by default: hovering past the notch shouldn't open it over your work.
        notchOpenOnClick = d.object(forKey: Self.notchOpenOnClickKey) as? Bool ?? true
        notchCloseDelay = clampN(Self.notchCloseDelayKey, 0.2, Self.notchCloseDelayRange)
        notchSize = NotchSize(rawValue: d.string(forKey: Self.notchSizeKey) ?? "") ?? .regular
        notchAnimation = NotchAnimation(rawValue: d.string(forKey: Self.notchAnimationKey) ?? "") ?? .island
        notchAnimationSpeed = clampN(Self.notchAnimationSpeedKey, 1, Self.notchAnimationSpeedRange)
        notchShowActivity = (d.object(forKey: Self.notchShowActivityKey) as? Bool) ?? true
        notchShowBattery = (d.object(forKey: Self.notchShowBatteryKey) as? Bool) ?? true
        notchShowKeepAwake = (d.object(forKey: Self.notchShowKeepAwakeKey) as? Bool) ?? true
        var tabs = Set(d.stringArray(forKey: Self.notchTabsKey) ?? ["notifications", "shelf", "clipboard", "timer", "battery"])
        // The Battery tab arrived later: switch it on once for existing setups.
        if !d.bool(forKey: "switch.notch.batteryTabAdded") {
            d.set(true, forKey: "switch.notch.batteryTabAdded")
            tabs.insert("battery")
            d.set(Array(tabs), forKey: Self.notchTabsKey)
        }
        if !d.bool(forKey: "switch.notch.notificationsTabAdded") {
            d.set(true, forKey: "switch.notch.notificationsTabAdded")
            tabs.insert("notifications")
            d.set(Array(tabs), forKey: Self.notchTabsKey)
        }
        // The System tab arrived later: switch it on once for existing setups.
        if !d.bool(forKey: "switch.notch.systemTabAdded") {
            d.set(true, forKey: "switch.notch.systemTabAdded")
            tabs.insert("system")
            d.set(Array(tabs), forKey: Self.notchTabsKey)
        }
        if !d.bool(forKey: "switch.notch.translateTabAdded") {
            d.set(true, forKey: "switch.notch.translateTabAdded")
            tabs.insert("translate")
            d.set(Array(tabs), forKey: Self.notchTabsKey)
        }
        if !d.bool(forKey: "switch.notch.portsTabAdded") {
            d.set(true, forKey: "switch.notch.portsTabAdded")
            tabs.insert("ports")
            d.set(Array(tabs), forKey: Self.notchTabsKey)
        }
        notchTabs = tabs
        notchTabBar = NotchTabBar(rawValue: d.string(forKey: Self.notchTabBarKey) ?? "") ?? .below
        notchHaptics = d.bool(forKey: Self.notchHapticsKey)
        notchHideInFullScreen = d.object(forKey: Self.notchHideInFullScreenKey) as? Bool ?? true
        // Older builds kept only a set of status items; lay them out on their usual sides.
        let oldStatus = Set(d.stringArray(forKey: Self.notchStatusItemsKey) ?? [])
        notchLeftItems = d.stringArray(forKey: Self.notchLeftItemsKey) ?? (["artwork"] + ["time", "date"].filter(oldStatus.contains))
        notchRightItems = d.stringArray(forKey: Self.notchRightItemsKey) ?? (["wifi", "battery"].filter(oldStatus.contains) + ["bars"])
        notchStatusWithActivity = (d.object(forKey: Self.notchStatusWithActivityKey) as? Bool) ?? true
        let storedDelay = (UserDefaults.standard.object(forKey: SwitchPreferences.dockPreviewDelayKey) as? Double) ?? 0.25
        dockPreviewDelay = min(max(storedDelay, Self.dockPreviewDelayRange.lowerBound), Self.dockPreviewDelayRange.upperBound)
        dockThumbSize = DockThumbSize(rawValue: UserDefaults.standard.string(forKey: SwitchPreferences.dockThumbSizeKey) ?? "") ?? .medium
        dockScrollCyclesWindows = UserDefaults.standard.bool(forKey: SwitchPreferences.dockScrollCyclesWindowsKey)
        showWindowCount = (UserDefaults.standard.object(forKey: SwitchPreferences.showWindowCountKey) as? Bool) ?? true
        currentDisplayOnly = UserDefaults.standard.bool(forKey: SwitchPreferences.currentDisplayOnlyKey)
        let storedVimNavigation = UserDefaults.standard.bool(forKey: SwitchPreferences.vimNavigationKey)
        vimNavigation = storedVimNavigation
        typeToFilter = storedVimNavigation
            ? false
            : (UserDefaults.standard.object(forKey: SwitchPreferences.typeToFilterKey) as? Bool) ?? true
        thumbnailHeight = (UserDefaults.standard.object(forKey: SwitchPreferences.thumbnailHeightKey) as? Double) ?? Self.defaultThumbnailHeight
        appIconSize = (UserDefaults.standard.object(forKey: SwitchPreferences.appIconSizeKey) as? Double) ?? Self.defaultAppIconSize
        gridColumns = (UserDefaults.standard.object(forKey: SwitchPreferences.gridColumnsKey) as? Int) ?? Self.defaultGridColumns
        maxListRows = (UserDefaults.standard.object(forKey: SwitchPreferences.maxListRowsKey) as? Int) ?? Self.defaultMaxListRows
        pinnedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: SwitchPreferences.pinnedBundleIDsKey) ?? [])
        pickerActivationDelay = (UserDefaults.standard.object(forKey: SwitchPreferences.pickerActivationDelayKey) as? Double) ?? Self.defaultPickerActivationDelay
        shiftTapReverses = UserDefaults.standard.bool(forKey: SwitchPreferences.shiftTapReversesKey)
        hideMinimizedWindows = UserDefaults.standard.bool(forKey: SwitchPreferences.hideMinimizedWindowsKey)
        showNumberKeyHints = UserDefaults.standard.bool(forKey: SwitchPreferences.showNumberKeyHintsKey)
        pickerDisplay = PickerDisplay(rawValue: UserDefaults.standard.string(forKey: SwitchPreferences.pickerDisplayKey) ?? "") ?? .mouse
    }
}
