import SwiftUI

/// Settings → Notch: the Dynamic Island on the notch. Applied live.
struct NotchSettingsTab: View {
    @ObservedObject private var prefs = SwitchPreferences.shared
    @ObservedObject private var shelf = FileShelf.shared
    @ObservedObject private var clipboard = ClipboardHistory.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(title: "Notch", subtitle: "Hover the notch to open it: Now Playing for any app, a file Shelf, clipboard history and a timer. Drag files onto the notch to keep them.") {
                    NotchIllustration()
                    SettingsCard {
                        SettingsToggle(title: "Dynamic Island on the notch", detail: "Closed, it looks like the notch, with the song or timer beside it.", isOn: $prefs.notchEnabled)
                    }
                }
                if prefs.notchEnabled { options }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var options: some View {
        SettingsSection(title: "Displays") {
            SettingsCard {
                SettingsRow(title: "Show on", detail: "Displays without a notch get a small pill at the top centre.") {
                    Picker("", selection: $prefs.notchDisplays) {
                        ForEach(SwitchPreferences.NotchDisplays.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                if prefs.notchDisplays == .chosen {
                    SettingsRow(title: "Display") {
                        Picker("", selection: $prefs.notchScreenName) {
                            ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                    .onAppear { if prefs.notchScreenName.isEmpty { prefs.notchScreenName = NSScreen.screens.first?.localizedName ?? "" } }
                }
            }
        }
        SettingsSection(title: "Alerts") {
            SettingsCard {
                SettingsRow(title: "Alerts show on", detail: "Notifications and battery alerts. All at once: every display with an island shows it together.") {
                    Picker("", selection: $prefs.alertDisplay) {
                        ForEach(SwitchPreferences.AlertDisplay.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                if prefs.alertDisplay == .chosen {
                    SettingsRow(title: "Display") {
                        Picker("", selection: $prefs.alertScreenName) {
                            ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                    .onAppear { if prefs.alertScreenName.isEmpty { prefs.alertScreenName = NSScreen.screens.first?.localizedName ?? "" } }
                }
            }
        }
        SettingsSection(title: "Opening and closing") {
            SettingsCard {
                SettingsRow(title: "Open the notch", detail: prefs.notchOpenOnClick
                            ? "Click the notch to open it; hovering only swells it a little, so passing the pointer by never opens it."
                            : "Rest the pointer on the notch to open it.") {
                    Picker("", selection: $prefs.notchOpenOnClick) {
                        Text("Click").tag(true)
                        Text("Hover").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
                if !prefs.notchOpenOnClick {
                    SettingsSlider(title: "Hover delay", value: seconds(prefs.notchHoverDelay), number: $prefs.notchHoverDelay,
                                   range: SwitchPreferences.notchHoverDelayRange, step: 0.02)
                }
                SettingsSlider(title: "Close after the pointer leaves", value: seconds(prefs.notchCloseDelay), number: $prefs.notchCloseDelay,
                               range: SwitchPreferences.notchCloseDelayRange, step: 0.1)
                SettingsToggle(title: "Haptic tap on open", detail: "A light tap on Force Touch trackpads.", isOn: $prefs.notchHaptics)
            }
        }
        SettingsSection(title: "Look and motion") {
            SettingsCard {
                SettingsSegmented(title: "Tabs", detail: "Below: a floating glass bar under the open island, like Droppy.",
                                  selection: $prefs.notchTabBar, options: SwitchPreferences.NotchTabBar.allCases, label: \.label, width: 260)
                SettingsSegmented(title: "Size when open", selection: $prefs.notchSize, options: SwitchPreferences.NotchSize.allCases, label: \.label, width: 240)
                SettingsSegmented(title: "Animation", detail: "Island widens first, then drops down, like the iPhone's Dynamic Island. Smooth never overshoots; Bouncy springs.",
                                  selection: $prefs.notchAnimation, options: SwitchPreferences.NotchAnimation.allCases, label: \.label, width: 240)
                SettingsSlider(title: "Animation speed", value: String(format: "%.1f×", prefs.notchAnimationSpeed), number: $prefs.notchAnimationSpeed,
                               range: SwitchPreferences.notchAnimationSpeedRange, step: 0.1)
            }
        }
        SettingsSection(title: "Full screen") {
            SettingsCard {
                SettingsToggle(title: "Hide in full screen", detail: "The island steps aside while an app or video fills its display, and comes back after.",
                               isOn: $prefs.notchHideInFullScreen)
            }
        }
        NotchStyleSection()
        SettingsSection(title: "Closed notch", subtitle: "What sits beside the notch when it's closed, and on which side.") {
            SettingsCard {
                SettingsToggle(title: "Song or timer", detail: "Artwork and bars while music plays, or a running timer.", isOn: $prefs.notchShowActivity)
                SettingsDivider()
                NotchLayoutEditor()
                SettingsDivider()
                SettingsToggle(title: "Keep them while music plays", detail: "Off: the song or timer takes the space and these come back when it stops.",
                               isOn: $prefs.notchStatusWithActivity)
            }
        }
        NotchNotificationSettings()
        if prefs.notchTabs.contains("system") { NotchSystemSettings() }
        if prefs.notchTabs.contains("ports") { NotchPortsSettings() }
        if prefs.notchTabs.contains("shelf") { NotchFilesSettings() }
        if prefs.notchTabs.contains("translate") { NotchTranslateSettings() }
        SettingsSection(title: "Content") {
            SettingsCard {
                tabToggle("shelf", "Files tab", "Files dropped on the notch: convert, compress, resize, PDF, zip and rename them.")
                tabToggle("clipboard", "Clipboard tab", "Recent text copies.")
                tabToggle("timer", "Timer tab", "Countdowns with a chime.")
                tabToggle("notifications", "Notifications tab", "Recent notifications from your apps, one row per sender.")
                tabToggle("battery", "Battery tab", "Health, power, capacity, the apps using energy and your devices.")
                tabToggle("system", "System tab", "CPU, memory, GPU, disk and network, with the busiest apps and a Quit button.")
                tabToggle("translate", "Translate tab", "⌃⌥C translates the selected text; IPA, listening and speaking practice, a phrase book.")
                tabToggle("ports", "Ports tab", "Dev servers listening on a port: folder, branch, memory; open or stop them.")
                SettingsDivider()
                SettingsToggle(title: "Clipboard history", detail: "Saved on this Mac only; password-manager copies are skipped.", isOn: $prefs.notchClipboardHistory)
                if prefs.notchClipboardHistory {
                    SettingsSegmented(title: "Keep clipboard", detail: "Older clips are removed; pinned clips stay until you unpin them.",
                                      selection: $prefs.notchClipboardRetention, options: SwitchPreferences.ClipboardRetention.allCases,
                                      label: \.label, width: 220)
                    .onChange(of: prefs.notchClipboardRetention) { clipboard.prune(force: true) }
                }
                SettingsToggle(title: "Battery in the top row", isOn: $prefs.notchShowBattery)
                SettingsToggle(title: "Keep Awake button", isOn: $prefs.notchShowKeepAwake)
            }
            HStack {
                Text("\(shelf.urls.count) on the Shelf · \(clipboard.clips.count) clips").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Shelf") { shelf.clear() }.controlSize(.small).disabled(shelf.urls.isEmpty)
                Button("Clear Clipboard") { clipboard.clearUnpinned() }.controlSize(.small).disabled(clipboard.clips.isEmpty)
            }
        }
    }

    private func tabToggle(_ key: String, _ title: String, _ detail: String) -> some View {
        SettingsToggle(title: title, detail: detail, isOn: Binding(
            get: { prefs.notchTabs.contains(key) },
            set: { on in
                var tabs = prefs.notchTabs
                if on { tabs.insert(key) } else { tabs.remove(key) }
                prefs.notchTabs = tabs
            }))
    }

    private func seconds(_ v: Double) -> String { "\(v.formatted(.number.precision(.fractionLength(0...2)))) s" }
}

/// Settings → Notch → Notifications.
private struct NotchNotificationSettings: View {
    @ObservedObject private var feed = NotificationFeed.shared

    private var bubbleSample: NotchAlert {
        NotchAlert(symbol: "bell.fill", title: "Mia Chen", detail: "Dinner at 8? I found a tiny Italian place", color: prefs.accent.color,
                   short: "Mia Chen", badge: "now", level: nil, appIcon: "com.apple.MobileSMS")
    }
    @ObservedObject private var prefs = SwitchPreferences.shared

    private var sample: NotchAlert {
        var alert = NotchAlert(symbol: "bell.fill", title: "Mia Chen", detail: "Dinner at 8? I found a tiny Italian place", color: .white,
                               short: "Mia Chen", badge: "now", level: nil, appIcon: "com.apple.MobileSMS")
        alert.style = feed.popup.style
        return alert
    }

    var body: some View {
        SettingsSection(title: "Notifications", subtitle: "Notifications from your other apps, in the notch. Read on this Mac from macOS's own list; nothing leaves it.") {
            SettingsCard {
                SettingsToggle(title: "Show notifications", detail: "The Notifications tab and alerts on the notch.", isOn: $feed.enabled)
                if feed.enabled {
                    SettingsRow(title: "Pop up as", detail: "On the notch: Banner (who and what), Compact (the wings), Icon (just the app's icon). Under the menu bar: Glass card, Pill, Vivid. Off: only in the tab.") {
                        Picker("", selection: $feed.popup) {
                            ForEach([NotificationFeed.Popup.banner, .compact, .icon]) { Text($0.label).tag($0) }
                            Divider()
                            ForEach([NotificationFeed.Popup.glass, .pill, .vivid]) { Text($0.label).tag($0) }
                            Divider()
                            Text("Off").tag(NotificationFeed.Popup.off)
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    if feed.popup != .off {
                        ZStack(alignment: .top) {
                            SampleDesktop()
                            if let theme = feed.popup.bubble {
                                AlertBubbleView(alert: bubbleSample, theme: theme, scale: 0.8, closable: false)
                                    .padding(.top, 14)
                                    .id(feed.popup)
                                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                            } else {
                                NotchAlertPreview(alert: sample, style: feed.popup.style ?? .expanded)
                                    .id(feed.popup)
                                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                            }
                        }
                        .frame(height: feed.popup.bubble == nil ? 100 : 120)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 16).padding(.bottom, 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: feed.popup)
                        SettingsSlider(title: "Stays for", value: "\(Int(feed.popupDuration)) s", number: $feed.popupDuration,
                                       range: NotificationFeed.popupDurationRange, step: 1)
                        SettingsToggle(title: "Get out of the way", detail: "The popup shrinks away as soon as the pointer comes near it, so it never sits over what you're doing.",
                                       isOn: $feed.dodgePointer)
                        SettingsToggle(title: "Show message text", detail: "Off: popups say only who it's from; read it in the tab.", isOn: $feed.showPreview)
                    }
                    SettingsDivider()
                    SettingsSlider(title: "Tab height", value: feed.tabExtra < 5 ? "Standard" : "+\(Int(feed.tabExtra)) pt · or drag the bar at the bottom of the tab",
                                   number: $feed.tabExtra, range: 0...NotificationFeed.maxTabExtra, step: 10)
                    SettingsSegmented(title: "Rows", detail: "Compact fits about twice as many.", selection: $feed.density,
                                      options: NotificationFeed.Density.allCases, label: \.label, width: 200)
                    SettingsDivider()
                    SettingsRow(title: "Full Disk Access", detail: feed.access == .granted ? "Allowed." : "Needed to read the notification list. Add win-tab, then come back.") {
                        if feed.access == .granted {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Open Privacy Settings") { NotificationFeed.openFullDiskAccessSettings() }
                        }
                    }
                    SettingsDivider()
                    NotificationSetupList()
                    if !feed.hiddenApps.isEmpty {
                        SettingsDivider()
                        ForEach(feed.hiddenApps.sorted(), id: \.self) { app in
                            SettingsRow(title: NotificationFeed.appName(app), detail: "Hidden") {
                                Button("Show again") { feed.unhide(app: app) }.controlSize(.small)
                            }
                        }
                    }
                }
            }
            .onAppear { feed.reload() }
        }
    }
}

/// Settings → Notch → Translate.
private struct NotchTranslateSettings: View {
    @AppStorage(TranslateModel.onlineKey) private var online = false
    @ObservedObject private var model = TranslateModel.shared

    var body: some View {
        SettingsSection(title: "Translate", subtitle: "⌃⌥C translates the selected text (or the clipboard). Change the shortcut in General → Hotkeys.") {
            SettingsCard {
                SettingsRow(title: "Translate into", detail: "Text already in this language goes into English instead.") {
                    Picker("", selection: $model.to) {
                        ForEach(Languages.all, id: \.self) { Text(Languages.label($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                SettingsDivider()
                SettingsToggle(title: "Online (Google)",
                               detail: "Sends the text to Google for languages or phrasing the Mac handles less well. Off: everything stays on this Mac.",
                               isOn: $online)
                SettingsDivider()
                SettingsSegmented(title: "Pronunciation", detail: "IPA and the reading voice: American or British.",
                                  selection: $model.accent, options: Pronunciation.Accent.allCases, label: \.label, width: 160)
            }
        }
    }
}

/// Settings → Notch → Files.
private struct NotchFilesSettings: View {
    @AppStorage(FileJobQueue.qualityKey) private var quality = 0.8
    @AppStorage(FileJobQueue.replaceOriginalKey) private var replaceOriginal = false

    var body: some View {
        SettingsSection(title: "Files", subtitle: "Results are saved next to the original. ⌃⌥D opens the Files tab (change it in General → Hotkeys).") {
            SettingsCard {
                SettingsSlider(title: "Quality", value: "\(Int((quality * 100).rounded()))% · JPG, HEIC and AVIF; lower is smaller",
                               number: $quality, range: 0.5...0.95, step: 0.05)
                SettingsDivider()
                SettingsToggle(title: "Replace the original",
                               detail: "The original goes to the Trash and the result takes its place. Off: both are kept.",
                               isOn: $replaceOriginal)
            }
        }
    }
}

/// Settings → Notch → Ports.
private struct NotchPortsSettings: View {
    @ObservedObject private var rules = PortRules.shared

    var body: some View {
        SettingsSection(title: "Ports", subtitle: "What the Ports tab leaves out. Apps (Postman, Chrome, Raycast…) and macOS's own services are never listed.") {
            SettingsCard {
                SettingsToggle(title: "Hide background services",
                               detail: "Started at login or by brew services (mongod, cliproxyapi…), not from a terminal or an agent.",
                               isOn: $rules.hideBackground)
                SettingsDivider()
                SettingsTokens(title: "Hide", detail: "A port (8317) or a program or folder name (cliproxyapi, linear-ui). The eye button on a row adds it here.",
                               items: $rules.hidden, placeholder: "Port or name")
                SettingsDivider()
                SettingsTokens(title: "Never stop", detail: "Programs Stop asks about before ending them, like databases.",
                               items: $rules.protected, placeholder: "Program name")
            }
        }
    }
}

/// Settings → Notch → System.
private struct NotchSystemSettings: View {
    @AppStorage(SystemMonitor.intervalKey) private var interval = 2.0
    @AppStorage(SystemMonitor.sortKey) private var sort: NotchSystemView.Sort = .cpu
    @AppStorage(NetworkInfo.lookupKey) private var publicIP = true

    var body: some View {
        SettingsSection(title: "System", subtitle: "Read only while the System tab is open; Energy Saver halves the rate.") {
            SettingsCard {
                SettingsRow(title: "Refresh", detail: "How often the numbers update.") {
                    Picker("", selection: $interval) {
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("5 s").tag(5.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
                SettingsToggle(title: "Public IP and country", detail: "Looked up at ipinfo.io when the Network page opens (it sees your IP). VPN and local IP stay on this Mac.",
                               isOn: $publicIP)
                SettingsSegmented(title: "Top apps by", detail: "Apps include their helper processes. Click × to quit, ⌥-click to force quit.",
                                  selection: $sort, options: NotchSystemView.Sort.allCases, label: \.label, width: 160)
            }
        }
    }
}
