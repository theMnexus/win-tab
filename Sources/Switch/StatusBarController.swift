import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configure(item)
        item.isVisible = !SwitchPreferences.shared.hideMenuBarIcon
    }

    private func configure(_ item: NSStatusItem) {
        if let button = item.button {
            let img = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "win-tab")
            img?.isTemplate = true
            button.image = img
        }

        let menu = NSMenu()

        let header = NSMenuItem(title: "win-tab", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About win-tab", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let saver = NSMenuItem(title: "Energy Saver", action: #selector(toggleEnergySaver(_:)), keyEquivalent: "")
        saver.target = self
        menu.addItem(saver)
        let picker = NSMenuItem(title: "Use win-tab for ⌘-Tab", action: #selector(togglePicker(_:)), keyEquivalent: "")
        picker.target = self
        menu.addItem(picker)
        menu.delegate = self

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit win-tab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
    }

    // Showing recreates the item: macOS won't reliably bring back an icon the user dragged off via isVisible alone.
    func setHidden(_ hidden: Bool) {
        if hidden {
            item.isVisible = false
        } else {
            NSStatusBar.system.removeStatusItem(item)
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            configure(item)
            item.isVisible = true
        }
    }

    /// On = Always, off = Off; "On battery" is picked in Settings → General.
    @objc private func toggleEnergySaver(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { EnergySaver.mode = EnergySaver.mode == .off ? .always : .off }
    }

    @objc private func togglePicker(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!HotkeyManager.pickerEnabled, forKey: HotkeyManager.pickerEnabledKey)
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            let saver = menu.items.first { $0.action == #selector(toggleEnergySaver(_:)) }
            saver?.state = EnergySaver.mode == .off ? .off : .on
            saver?.title = EnergySaver.mode == .battery ? "Energy Saver (on battery)" : "Energy Saver"
            menu.items.first { $0.action == #selector(togglePicker(_:)) }?.state = HotkeyManager.pickerEnabled ? .on : .off
        }
    }

    @objc private func openSettings() {
        MainActor.assumeIsolated { SettingsWindow.shared.show() }
    }

    @objc private func openAbout() {
        MainActor.assumeIsolated { AboutWindow.shared.show() }
    }
}
