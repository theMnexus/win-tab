import AppKit
import Combine

/// Tells when Mission Control or App Exposé is on screen, so the notch and win-tab's Dock can
/// step aside (Mission Control draws Apple's own Dock, and a second one sat on top of it).
///
/// macOS posts nothing for it (the Dock's `AXExpose…` notifications no longer fire), and a
/// window-list poll costs 1–6 ms a call. Instead a 2×2 pt invisible `.transient` window stays on
/// every Space: Mission Control hides transient windows, so its occlusion flips to hidden about
/// 0.35 s after Mission Control starts and back within 0.03 s of it ending. A Space animation
/// (going full screen) also hides it briefly, so a hidden sentinel is confirmed with one window
/// list read: during Mission Control the Dock owns a window covering a whole display.
@MainActor
final class MissionControlWatch {
    static let shared = MissionControlWatch()

    /// Published before it changes: subscribers that read `isActive` back hop to the next turn
    /// of the main queue first (`receive(on:)`).
    @Published private(set) var isActive = false

    private var sentinel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var recheck: DispatchWorkItem?
    /// Mission Control's windows can trail the occlusion change by a frame or two.
    private static let recheckDelay: TimeInterval = 0.25

    func start() {
        guard sentinel == nil else { return }
        place()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
    }

    /// One sentinel in a corner of the main display, above every win-tab window so none of them
    /// can occlude it.
    private func place() {
        let panel = sentinel ?? makeSentinel()
        sentinel = panel
        guard let screen = NSScreen.screens.first else { return }
        panel.setFrame(CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 2, height: 2), display: false)
        panel.orderFrontRegardless()
    }

    private func makeSentinel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 2, height: 2), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Full-screen auxiliary: stays visible in a full-screen Space, so that isn't read as Mission Control.
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        })
        return panel
    }

    private func occlusionChanged() {
        recheck?.cancel()
        recheck = nil
        guard let sentinel, !sentinel.occlusionState.contains(.visible) else {
            set(false)
            return
        }
        if Self.dockCoversADisplay() {
            set(true)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let s = self.sentinel, !s.occlusionState.contains(.visible) else { return }
            self.set(Self.dockCoversADisplay())
        }
        recheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recheckDelay, execute: work)
    }

    private func set(_ active: Bool) {
        if active != isActive { isActive = active }
    }

    /// Mission Control and App Exposé: a Dock window above normal windows the size of a display.
    private static func dockCoversADisplay() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let displays = NSScreen.screens.map(\.frame.size)
        return list.contains { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "Dock", (w[kCGWindowLayer as String] as? Int ?? 0) > 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
            return displays.contains { abs($0.width - bounds.width) < 1 && abs($0.height - bounds.height) < 1 }
        }
    }
}

