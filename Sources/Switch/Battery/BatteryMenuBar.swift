import AppKit
import Combine
import SwiftUI

/// Settings → Battery → Battery in the menu bar: an iPhone-style battery; click it for details.
@MainActor
final class BatteryMenuBar {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var drawnKey = ""

    func start() {
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: BatteryPopover())
        BatteryPreferences.shared.objectWillChange.merge(with: BatteryMonitor.shared.objectWillChange)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &cancellables)
        update()
    }

    private func update() {
        let prefs = BatteryPreferences.shared
        guard prefs.menuBarIcon, let b = BatteryMonitor.shared.state else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            drawnKey = ""
            return
        }
        if item == nil {
            let made = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            made.button?.target = self
            made.button?.action = #selector(toggle)
            item = made
        }
        let key = "\(b.percent)|\(b.charging)|\(prefs.menuBarStyle)|\(prefs.menuBarPercent)"
        guard key != drawnKey, let button = item?.button else { return }
        drawnKey = key
        button.image = Self.image(b, style: prefs.menuBarStyle, percentInside: prefs.menuBarPercent)
        button.toolTip = "\(b.percent)% · \(b.timeLabel)"
    }

    /// Minimal renders as a template so macOS tints it for the menu bar; Colour keeps its colours.
    private static func image(_ b: BatteryDetails, style: BatteryPreferences.MenuBarStyle, percentInside: Bool) -> NSImage? {
        let colour = style == .colour
        let glyph = BatteryGlyph(percent: b.percent, charging: b.charging,
                                 color: colour ? BatteryPalette.color(percent: b.percent, charging: b.charging) : .black,
                                 showsPercent: percentInside, height: 12)
        let renderer = ImageRenderer(content: glyph.padding(.vertical, 1))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = !colour
        return image
    }

    @objc private func toggle() {
        MainActor.assumeIsolated {
            guard let button = item?.button else { return }
            if popover.isShown {
                popover.performClose(nil)
            } else {
                BatteryMonitor.shared.refresh(accessories: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
}

private struct BatteryPopover: View {
    @ObservedObject private var monitor = BatteryMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let b = monitor.state {
                BatteryHero(battery: b, compact: true)
                BatteryStatsGrid(battery: b, columns: 2)
            }
            if !monitor.accessories.isEmpty {
                Divider()
                AccessoryBatteryList(accessories: monitor.accessories).padding(.horizontal, -14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Battery Settings…") { SettingsWindow.shared.show(tab: "battery") }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
