import AppKit
import IOKit.ps

/// Energy Saver: win-tab's background checks (Apple's Dock badges and dots, full-screen
/// detection, Dock health) run a third as often. The ⌘-Tab picker, hotkeys, hovering and the
/// Dock's edge reveal never slow down.
@MainActor
enum EnergySaver {
    enum Mode: String, CaseIterable, Identifiable {
        case off, battery, always
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .battery: return "On battery"
            case .always: return "Always"
            }
        }
    }

    static let key = "switch.energySaver"
    /// Background checks run once every this many ticks while saving.
    static let stretch = 3

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    static var isOn: Bool {
        switch mode {
        case .off: return false
        case .always: return true
        case .battery: return ProcessInfo.processInfo.isLowPowerModeEnabled || onBattery
        }
    }

    private static var batteryCache: (value: Bool, at: CFTimeInterval)?

    /// Power source, re-read at most every 30 s (it's an IPC call).
    private static var onBattery: Bool {
        let now = CACurrentMediaTime()
        if let c = batteryCache, now - c.at < 30 { return c.value }
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        let value = type == kIOPMBatteryPowerKey
        batteryCache = (value, now)
        return value
    }

    /// Lets a repeating check through every tick normally, every `stretch` ticks while saving.
    struct Gate {
        private var skipped = 0

        @MainActor
        mutating func pass() -> Bool {
            guard EnergySaver.isOn else { skipped = 0; return true }
            skipped += 1
            guard skipped >= EnergySaver.stretch else { return false }
            skipped = 0
            return true
        }
    }
}
