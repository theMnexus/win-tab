import AppKit

/// One slot in your own Dock arrangement, saved in preferences.
struct DockEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case app, folder, group, spacer, divider, widget, stack }

    var id = UUID()
    var kind: Kind
    /// App bundle or folder path.
    var path: String?
    /// Group name.
    var name: String?
    /// Group members (app bundle paths).
    var apps: [String] = []
    var widget: DockWidgetKind?
    /// Smart Stack members. Optional so entries saved before stacks existed still decode.
    var widgets: [DockWidgetKind]?

    static func app(_ path: String) -> Self { DockEntry(kind: .app, path: path) }
    static func folder(_ path: String) -> Self { DockEntry(kind: .folder, path: path) }
    static func group(_ name: String, apps: [String] = []) -> Self { DockEntry(kind: .group, name: name, apps: apps) }
    static var spacer: Self { DockEntry(kind: .spacer) }
    static var divider: Self { DockEntry(kind: .divider) }
    static func widget(_ w: DockWidgetKind) -> Self { DockEntry(kind: .widget, widget: w) }
    static var smartStack: Self { DockEntry(kind: .stack, widgets: [.nowPlaying, .calendar, .clock, .battery]) }

    var title: String {
        switch kind {
        case .app, .folder: return path.map(DockEntry.displayName) ?? ""
        case .group: return name ?? "Group"
        case .spacer: return "Spacer"
        case .divider: return "Divider"
        case .widget: return widget?.label ?? "Widget"
        case .stack: return "Smart Stack"
        }
    }

    static func displayName(_ path: String) -> String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    /// Apple's Dock as a starting point: its apps and folders, in order.
    static func seedFromAppleDock() -> [DockEntry] {
        var out: [DockEntry] = []
        var addedDivider = false
        for item in DockAX.items() {
            guard let path = item.url?.path else { continue }
            if item.isApp {
                out.append(.app(path))
            } else if item.subrole == DockAX.folderSubrole {
                if !addedDivider { out.append(.divider); addedDivider = true }
                out.append(.folder(path))
            }
        }
        return out
    }
}

enum DockWidgetKind: String, Codable, CaseIterable, Identifiable {
    case nowPlaying, clock, calendar, battery
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .clock: return "Clock"
        case .calendar: return "Date"
        case .battery: return "Battery"
        }
    }
    var symbol: String {
        switch self {
        case .nowPlaying: return "play.circle"
        case .clock: return "clock"
        case .calendar: return "calendar"
        case .battery: return "battery.75percent"
        }
    }
    /// Length along the Dock in icon sizes; vertical Docks get the squarer form.
    func units(vertical: Bool) -> CGFloat {
        switch self {
        case .nowPlaying: return vertical ? 2 : 4
        case .clock: return vertical ? 1 : 2
        case .calendar, .battery: return 1
        }
    }
}
