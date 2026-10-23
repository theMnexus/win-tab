import SwiftUI

/// Settings → Dock: win-tab's Dock add-ons (applied live) and the Apple Dock's own options
/// (applied on demand, since each apply restarts the Dock).
struct DockSettingsTab: View {
    @ObservedObject private var prefs = SwitchPreferences.shared
    @StateObject private var dock = DockSystemSettings()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(title: "win-tab Dock", subtitle: "Your own Dock: groups, folders, widgets, any edge, a place per display. The preview follows every setting below.") {
                    DockLivePreview()
                    SettingsCard {
                        feature(.customDock, "Use win-tab's Dock", "Drag the grip at its start to move it along the edge or to another edge.", $prefs.customDockEnabled)
                    }
                }
                if prefs.customDockEnabled { customDockSettings }

                section("win-tab on the Dock") {
                    card {
                        feature(.previews, "Window previews on hover", "Hover an app in the Dock to see its windows. Click one to switch to it.", $prefs.dockPreviews)
                        divider
                        feature(.labels, "Replace Dock labels", "Show win-tab's card (name, status, badge) instead of the Dock's name bubble. Quitting win-tab brings the bubble back.", $prefs.dockReplaceLabels)
                        divider
                        feature(.badges, "Unread badges in the picker", "Mirror the red Dock badges (Zalo, Telegram…) onto app icons in ⌘-Tab.", $prefs.showDockBadges)
                        divider
                        feature(.clickToHide, "Click to hide", "Clicking the icon of the app you're already in hides it, like on Windows.", $prefs.dockClickToHide)
                        divider
                        feature(.scroll, "Scroll to cycle windows", "Scroll over an app's Dock icon to step through its windows.", $prefs.dockScrollCyclesWindows)
                    }
                }

                section("Hover card") {
                    card {
                        slider("Show after", seconds(prefs.dockPreviewDelay), $prefs.dockPreviewDelay, SwitchPreferences.dockPreviewDelayRange, step: 0.05)
                        divider
                        row("Thumbnail size", "") {
                            Picker("", selection: $prefs.dockThumbSize) {
                                ForEach(SwitchPreferences.DockThumbSize.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                        }
                    }
                    Text("The card uses the picker's Background (Appearance tab) and Animation speed.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                section("macOS Dock") {
                    card {
                        row("Position", "") {
                            Picker("", selection: $dock.position) {
                                ForEach(DockSystemSettings.Position.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                        }
                        divider
                        slider("Icon size", "\(Int(dock.iconSize)) pt", $dock.iconSize, DockSystemSettings.iconSizeRange, step: 2)
                        divider
                        toggle("Magnification", "Enlarge icons under the pointer.", $dock.magnification)
                        if dock.magnification {
                            slider("Magnified size", "\(Int(dock.magnifiedSize)) pt", $dock.magnifiedSize, DockSystemSettings.iconSizeRange, step: 2)
                        }
                        divider
                        toggle("Automatically hide the Dock", "", $dock.autohide)
                        if dock.autohide {
                            slider("Show delay", seconds(dock.autohideDelay), $dock.autohideDelay, DockSystemSettings.secondsRange, step: 0.05)
                            slider("Show/hide animation", seconds(dock.autohideDuration), $dock.autohideDuration, DockSystemSettings.secondsRange, step: 0.05)
                        }
                        divider
                        row("Minimize effect", "") {
                            Picker("", selection: $dock.minimizeEffect) {
                                ForEach(DockSystemSettings.MinimizeEffect.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().frame(width: 110)
                        }
                        divider
                        toggle("Show recent apps", "", $dock.showRecents)
                        divider
                        toggle("Dim hidden apps", "Hidden apps get a translucent icon.", $dock.dimHiddenApps)
                    }
                    HStack {
                        if let error = dock.lastError {
                            Text(error).font(.system(size: 11)).foregroundStyle(.red)
                        } else {
                            Text("Applying restarts the Dock for a moment.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revert") { dock.reload() }.controlSize(.small).disabled(!dock.hasChanges)
                        Button("Apply") { dock.apply() }
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!dock.hasChanges)
                    }
                }
            }
            .padding(24)
        }
        .onAppear { dock.reload() }
    }

    /// Displays that have a win-tab Dock: the main one, or all of them.
    private var dockScreens: [NSScreen] {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        return prefs.customDockAllDisplays ? NSScreen.screens : primary.map { [$0] } ?? []
    }

    private func edgeBinding(_ screen: NSScreen) -> Binding<ScreenEdge> {
        Binding(get: { prefs.dockPlacement(for: screen).edge },
                set: { prefs.setDockPlacement($0, offset: prefs.dockPlacement(for: screen).offset, for: screen) })
    }

    private func offsetBinding(_ screen: NSScreen) -> Binding<Double> {
        Binding(get: { prefs.dockPlacement(for: screen).offset },
                set: { prefs.setDockPlacement(prefs.dockPlacement(for: screen).edge, offset: $0, for: screen) })
    }

    @ViewBuilder
    private var customDockSettings: some View {
        SettingsSection(title: "Position", subtitle: "Each display keeps its own edge and place, e.g. the main display at the bottom and another on the right.") {
            SettingsCard {
                SettingsToggle(title: "Show on every display", detail: "One Dock per display. Off: only the main display.", isOn: $prefs.customDockAllDisplays)
                ForEach(dockScreens, id: \.localizedName) { screen in
                    SettingsDivider()
                    SettingsSegmented(title: screen.localizedName, detail: screen == NSScreen.screens.first ? "Main display" : "",
                                      selection: edgeBinding(screen), options: ScreenEdge.allCases, label: \.label)
                    SettingsSlider(title: "Position along the edge", value: "\(Int(offsetBinding(screen).wrappedValue * 100))%",
                                   number: offsetBinding(screen), range: 0...1, step: 0.01)
                }
                if let main = NSScreen.screens.first, prefs.dockPlacement(for: main).edge == DockGeometry.current.edge && !prefs.customDockHideSystemDock {
                    Text("The macOS Dock is on the main display's edge too, so both compete for the pointer. Pick another edge or turn on Hide the macOS Dock.")
                        .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
        }
        SettingsSection(title: "Look") {
            SettingsCard {
                SettingsSegmented(title: "Bar", detail: "Glass needs macOS 26; elsewhere it falls back to Blur.",
                                  selection: $prefs.customDockBarStyle, options: SwitchPreferences.DockBarStyle.allCases, label: \.label)
                SettingsSlider(title: "Corner radius", value: "\(Int(prefs.customDockCornerRadius)) pt", number: $prefs.customDockCornerRadius,
                               range: SwitchPreferences.customDockCornerRadiusRange)
                SettingsSlider(title: "Icon size", value: "\(Int(prefs.customDockIconSize)) pt", number: $prefs.customDockIconSize,
                               range: SwitchPreferences.customDockIconRange, step: 2)
                SettingsDivider()
                SettingsSegmented(title: "Widgets", selection: $prefs.customDockWidgetStyle, options: SwitchPreferences.DockWidgetStyle.allCases,
                                  label: \.label, width: 200)
                SettingsSegmented(title: "Running indicator", selection: $prefs.customDockIndicator, options: SwitchPreferences.DockIndicator.allCases,
                                  label: \.label, width: 200)
                SettingsToggle(title: "Unread badges", detail: "Red counts from apps like Telegram and Zalo.", isOn: $prefs.customDockShowBadges)
            }
        }
        DockStyleSection()
        SettingsSection(title: "Hover") {
            SettingsCard {
                SettingsSegmented(title: "Effect", detail: "Magnify pushes neighbours apart like Apple's Dock; Lift raises the icon; Glow lights it up.",
                                  selection: $prefs.customDockHoverEffect, options: SwitchPreferences.DockHoverEffect.allCases, label: \.label)
                if prefs.customDockHoverEffect == .magnify {
                    SettingsSlider(title: "Magnified size", value: "\(Int(prefs.customDockMagnifiedSize)) pt · \(Int((prefs.customDockMagnifiedSize / prefs.customDockIconSize * 100).rounded()))%", number: $prefs.customDockMagnifiedSize,
                                   range: SwitchPreferences.customDockMagnifiedRange, step: 2)
                    SettingsSlider(title: "Spread", value: String(format: "%.1f icons", prefs.customDockSpread), number: $prefs.customDockSpread,
                                   range: SwitchPreferences.customDockSpreadRange, step: 0.1)
                } else if prefs.customDockHoverEffect != .none {
                    SettingsSlider(title: "Zoom", value: String(format: "%.0f%%", prefs.customDockHoverZoom * 100), number: $prefs.customDockHoverZoom,
                                   range: SwitchPreferences.customDockHoverZoomRange, step: 0.01)
                }
                SettingsDivider()
                SettingsSegmented(title: "Motion", detail: "Smooth follows the pointer exactly and eases in and out.",
                                  selection: $prefs.customDockHoverMotion, options: SwitchPreferences.DockHoverMotion.allCases, label: \.label)
                SettingsToggle(title: "Bounce on click", isOn: $prefs.customDockClickBounce)
            }
        }
        SettingsSection(title: "Spacing") {
            SettingsCard {
                SettingsSlider(title: "Between icons", value: "\(Int(prefs.customDockSpacing)) pt", number: $prefs.customDockSpacing,
                               range: SwitchPreferences.customDockSpacingRange)
                SettingsSlider(title: "Inside the bar", value: "\(Int(prefs.customDockPadding)) pt", number: $prefs.customDockPadding,
                               range: SwitchPreferences.customDockPaddingRange)
                SettingsSlider(title: "From the screen edge", value: "\(Int(prefs.customDockMargin)) pt", number: $prefs.customDockMargin,
                               range: SwitchPreferences.customDockMarginRange)
                SettingsSlider(title: "Around widgets", value: "\(Int(prefs.customDockWidgetGap)) pt", number: $prefs.customDockWidgetGap,
                               range: SwitchPreferences.customDockWidgetGapRange)
            }
        }
        SettingsSection(title: "Behaviour") {
            SettingsCard {
                SettingsToggle(title: "Automatically hide", detail: "Tucks away and leaves a thin bar at the edge; hover or click the bar, or push the pointer into the edge, to bring it back.",
                               isOn: $prefs.customDockAutoHide)
                if prefs.customDockAutoHide {
                    SettingsSlider(title: "Hide after", value: seconds(prefs.customDockAutoHideDelay), number: $prefs.customDockAutoHideDelay,
                                   range: SwitchPreferences.customDockAutoHideDelayRange, step: 0.1)
                    SettingsSegmented(title: "Animation", selection: $prefs.customDockHideStyle,
                                      options: SwitchPreferences.DockHideStyle.allCases, label: \.label)
                    SettingsSlider(title: "Animation speed", value: seconds(prefs.customDockHideDuration), number: $prefs.customDockHideDuration,
                                   range: SwitchPreferences.customDockHideDurationRange, step: 0.02)
                    SettingsSegmented(title: "Bar while hidden", detail: "Auto is white in Dark Mode and black in Light Mode. Glass is a Liquid Glass sliver.",
                                      selection: $prefs.customDockRevealBar, options: SwitchPreferences.DockRevealBar.allCases, label: \.label, width: 340)
                    DockRevealBarStyleRows()
                }
                SettingsDivider()
                SettingsSegmented(title: "Drag grip", detail: "At the start: shows only when the pointer reaches the Dock's start. Hold ⌥: shows, and any drag moves the Dock, while Option is down. Never: drag the bar's empty space instead.",
                                  selection: $prefs.customDockGripMode, options: SwitchPreferences.DockGripMode.allCases, label: \.label, width: 290)
                SettingsToggle(title: "Show Trash", detail: "At the end of the Dock. Click to open it, drop files on it to throw them away, drop a Dock item on it to take it off, right-click to empty it.",
                               isOn: $prefs.customDockShowTrash)
                SettingsToggle(title: "Hide the macOS Dock", detail: "Turning this off or quitting win-tab brings it back.", isOn: $prefs.customDockHideSystemDock)
                SettingsDivider()
                Text("On the Dock: drag an icon to move it, drop it onto another app to make a group; right-click for New Group, Rename and Ungroup.")
                    .font(.system(size: 11)).foregroundStyle(prefs.accent.color).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                SettingsToggle(title: "Arrange my own items", detail: "Groups, folders, widgets, Smart Stacks, spacers, dividers. Off: the macOS Dock's apps.",
                               isOn: Binding(get: { prefs.customDockUseOwnItems }, set: { on in
                                   if on && prefs.customDockEntries.isEmpty { prefs.customDockEntries = DockEntry.seedFromAppleDock() }
                                   prefs.customDockUseOwnItems = on
                               }))
            }
        }
        if prefs.customDockUseOwnItems {
            SettingsSection(title: "Dock items") {
                SettingsCard { DockItemsEditor() }
            }
        }
    }

    private func seconds(_ v: Double) -> String { "\(v.formatted(.number.precision(.fractionLength(0...2)))) s" }

    private var divider: some View { Divider().opacity(0.4) }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(prefs.accent.color).frame(width: 5, height: 5)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            )
    }

    private func row<Trailing: View>(_ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func feature(_ kind: DockIllustration.Kind, _ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            DockIllustration(kind: kind, accent: prefs.accent.color)
                .opacity(isOn.wrappedValue ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(prefs.accent.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        row(title, detail) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(prefs.accent.color)
        }
    }

    private func slider(_ title: String, _ value: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        row(title, value) {
            Slider(value: binding, in: range, step: step).frame(width: 160).tint(prefs.accent.color)
        }
    }
}
