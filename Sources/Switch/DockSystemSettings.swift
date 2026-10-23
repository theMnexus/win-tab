import AppKit

/// The Apple Dock's own preferences (`defaults write com.apple.dock …`). Edits stay local until
/// `apply()`, which writes them and restarts the Dock, the only way it picks them up.
@MainActor
final class DockSystemSettings: ObservableObject {
    enum Position: String, CaseIterable, Identifiable {
        case left, bottom, right
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum MinimizeEffect: String, CaseIterable, Identifiable {
        case genie, scale, suck
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    static let iconSizeRange: ClosedRange<Double> = 16...128
    static let secondsRange: ClosedRange<Double> = 0...2

    @Published var autohide = false
    @Published var autohideDelay: Double = 0.5
    @Published var autohideDuration: Double = 0.5
    @Published var iconSize: Double = 48
    @Published var magnification = false
    @Published var magnifiedSize: Double = 64
    @Published var position: Position = .bottom
    @Published var minimizeEffect: MinimizeEffect = .genie
    @Published var showRecents = true
    @Published var dimHiddenApps = false
    @Published private(set) var lastError: String?

    private let domain = DockAX.bundleID as CFString
    /// Values as last read, so apply() only writes keys the user actually changed.
    private var loaded: [String: AnyHashable] = [:]

    init() { reload() }

    func reload() {
        autohide = bool("autohide") ?? false
        autohideDelay = double("autohide-delay") ?? 0.5
        autohideDuration = double("autohide-time-modifier") ?? 0.5
        iconSize = double("tilesize") ?? 48
        magnification = bool("magnification") ?? false
        magnifiedSize = double("largesize") ?? 64
        position = string("orientation").flatMap(Position.init(rawValue:)) ?? .bottom
        minimizeEffect = string("mineffect").flatMap(MinimizeEffect.init(rawValue:)) ?? .genie
        showRecents = bool("show-recents") ?? true
        dimHiddenApps = bool("showhidden") ?? false
        loaded = currentValues()
        lastError = nil
    }

    var hasChanges: Bool { currentValues() != loaded }

    private func currentValues() -> [String: AnyHashable] {
        [
            "autohide": autohide,
            "autohide-delay": autohideDelay,
            "autohide-time-modifier": autohideDuration,
            "tilesize": Int(iconSize),
            "magnification": magnification,
            "largesize": Int(magnifiedSize),
            "orientation": position.rawValue,
            "mineffect": minimizeEffect.rawValue,
            "show-recents": showRecents,
            "showhidden": dimHiddenApps,
        ]
    }

    func apply() {
        let values = currentValues()
        let changed = values.filter { loaded[$0.key] != $0.value }
        guard !changed.isEmpty else { return }
        for (key, value) in changed { set(key, value) }
        guard CFPreferencesAppSynchronize(domain) else {
            lastError = "Could not save Dock preferences."
            return
        }
        loaded = values
        restartDock()
    }

    private func restartDock() {
        do {
            try Self.restartAppleDock()
            lastError = nil
        } catch {
            lastError = "Saved, but restarting the Dock failed: \(error.localizedDescription)"
        }
    }

    /// The Dock only rereads its preferences on launch.
    nonisolated static func restartAppleDock() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try p.run()
    }

    private func value(_ key: String) -> CFPropertyList? { CFPreferencesCopyAppValue(key as CFString, domain) }
    private func bool(_ key: String) -> Bool? { value(key) as? Bool }
    private func double(_ key: String) -> Double? { (value(key) as? NSNumber)?.doubleValue }
    private func string(_ key: String) -> String? { value(key) as? String }
    private func set(_ key: String, _ value: Any) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList, domain)
    }
}

/// Hides Apple's Dock behind win-tab's by making it auto-hide with a huge reveal delay, the only
/// lever that needs no injection. The original values are backed up in win-tab's defaults and
/// restored when the option goes off, when win-tab quits, and on the next launch after a crash.
/// ponytail: no watchdog process; a crash leaves the Dock hidden until win-tab starts again.
enum SystemDockHider {
    private static let backupKey = "switch.systemDockBackup"
    private static let unsetMarker = "__unset__"
    private static let domain = DockAX.bundleID as CFString
    /// `no-bouncing`: an auto-hidden Dock slides out while an icon bounces, whatever the delay;
    /// win-tab's Dock does the bouncing instead (see `AttentionWatch`).
    private static let hiddenValues: [String: Any] = ["autohide": true, "autohide-delay": 1000.0, "no-bouncing": true]

    static var isHiding: Bool { UserDefaults.standard.dictionary(forKey: backupKey) != nil }

    /// Also catches up a backup made before a key was added here (no-bouncing): that key is
    /// backed up and applied, and the Dock restarted once.
    static func hide() {
        var backup = UserDefaults.standard.dictionary(forKey: backupKey) ?? [:]
        let missing = hiddenValues.keys.filter { backup[$0] == nil }
        guard !missing.isEmpty else { return }
        for key in missing {
            backup[key] = CFPreferencesCopyAppValue(key as CFString, domain) ?? unsetMarker as CFString
        }
        UserDefaults.standard.set(backup, forKey: backupKey)
        for key in missing {
            if let value = hiddenValues[key] { CFPreferencesSetAppValue(key as CFString, value as CFPropertyList, domain) }
        }
        apply()
    }

    static func restore() {
        guard let backup = UserDefaults.standard.dictionary(forKey: backupKey) else { return }
        for key in hiddenValues.keys {
            let value = backup[key]
            let restored: CFPropertyList? = (value as? String) == unsetMarker ? nil : value as CFPropertyList?
            CFPreferencesSetAppValue(key as CFString, restored, domain)
        }
        UserDefaults.standard.removeObject(forKey: backupKey)
        apply()
    }

    private static func apply() {
        CFPreferencesAppSynchronize(domain)
        do { try DockSystemSettings.restartAppleDock() } catch { NSLog("win-tab: Dock restart failed: \(error)") }
    }
}
