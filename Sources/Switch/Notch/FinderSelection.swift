import AppKit

/// The files selected in Finder, read over AppleScript (Automation → Finder, as the Trash
/// button already uses), off the main thread on one serial queue (NSAppleScript isn't
/// safe across threads).
@MainActor
enum FinderSelection {
    private static let queue = DispatchQueue(label: "win-tab.finder-selection", qos: .userInitiated)
    private static let script = """
    tell application "Finder"
        set out to ""
        repeat with f in (get selection as alias list)
            set out to out & POSIX path of f & linefeed
        end repeat
        return out
    end tell
    """

    /// Calls back with the selection (empty when Finder isn't in front or nothing is selected),
    /// or nil when win-tab isn't allowed to control Finder.
    static func read(_ done: @escaping @MainActor ([URL]?) -> Void) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
            done([])
            return
        }
        let source = script
        queue.async {
            var error: NSDictionary?
            let text = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
            let denied = (error?[NSAppleScript.errorNumber] as? Int) == -1743
            let urls = text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(denied ? nil : urls) } }
        }
    }
}
