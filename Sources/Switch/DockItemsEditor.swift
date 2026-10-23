import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Dock → Items: your own Dock arrangement. Changes apply live.
struct DockItemsEditor: View {
    @ObservedObject private var prefs = SwitchPreferences.shared
    @State private var expandedGroup: UUID?

    private var entries: [DockEntry] { prefs.customDockEntries }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text("No items yet. Add apps, folders, groups or widgets below.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(14)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                row(entry, index: i)
                if entry.kind == .group && expandedGroup == entry.id { groupMembers(entry) }
                if entry.kind == .stack { stackMembers(entry) }
                Divider().opacity(0.4)
            }
            HStack(spacing: 10) {
                Menu {
                    Button("App…") { addApps() }
                    Button("Folder…") { addFolder() }
                    Button("Group") {
                        let group = DockEntry.group("Group \(entries.filter { $0.kind == .group }.count + 1)")
                        update { $0.append(group) }
                        expandedGroup = group.id
                    }
                    Divider()
                    Menu("Widget") {
                        ForEach(DockWidgetKind.allCases) { kind in
                            Button(kind.label) { update { $0.append(.widget(kind)) } }
                        }
                    }
                    Button("Smart Stack") { update { $0.append(.smartStack) } }
                    Button("Spacer") { update { $0.append(.spacer) } }
                    Button("Divider") { update { $0.append(.divider) } }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button("Copy macOS Dock") { prefs.customDockEntries = DockEntry.seedFromAppleDock() }
                    .controlSize(.small)
                    .help("Replace these items with the apps and folders on Apple's Dock.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func row(_ entry: DockEntry, index i: Int) -> some View {
        HStack(spacing: 10) {
            icon(entry).frame(width: 22, height: 22)
            if entry.kind == .group {
                TextField("Group name", text: Binding(
                    get: { entry.name ?? "" },
                    set: { name in update { $0 = $0.map { $0.id == entry.id ? $0.renamed(name) : $0 } } }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                Button(expandedGroup == entry.id ? "Done" : "\(entry.apps.count) apps") {
                    expandedGroup = expandedGroup == entry.id ? nil : entry.id
                }
                .controlSize(.small)
            } else {
                Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(kindLabel(entry)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            iconButton("chevron.up", disabled: i == 0) { update { $0.swapAt(i, i - 1) } }
            iconButton("chevron.down", disabled: i == entries.count - 1) { update { $0.swapAt(i, i + 1) } }
            iconButton("xmark", disabled: false) { update { $0.remove(at: i) } }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func groupMembers(_ group: DockEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(group.apps, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                    Text(DockEntry.displayName(path)).font(.system(size: 12))
                    Spacer()
                    iconButton("minus.circle", disabled: false) {
                        update { $0 = $0.map { $0.id == group.id ? $0.withApps($0.apps.filter { $0 != path }) : $0 } }
                    }
                }
            }
            Button("Add apps to group…") {
                let picked = pickApps().filter { !group.apps.contains($0) }
                update { $0 = $0.map { $0.id == group.id ? $0.withApps($0.apps + picked) : $0 } }
            }
            .controlSize(.small)
        }
        .padding(.leading, 46)
        .padding(.trailing, 14)
        .padding(.bottom, 8)
    }

    /// Which widgets a Smart Stack flips through.
    private func stackMembers(_ stack: DockEntry) -> some View {
        HStack(spacing: 6) {
            ForEach(DockWidgetKind.allCases) { kind in
                let on = stack.widgets?.contains(kind) ?? false
                Button {
                    let current = stack.widgets ?? []
                    let next = on ? current.filter { $0 != kind } : current + [kind]
                    update { $0 = $0.map { $0.id == stack.id ? $0.withWidgets(next) : $0 } }
                } label: {
                    Label(kind.label, systemImage: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(on ? prefs.accent.color : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.leading, 46)
        .padding(.trailing, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func icon(_ entry: DockEntry) -> some View {
        switch entry.kind {
        case .app, .folder:
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path ?? "")).resizable()
        case .group:
            Image(systemName: "square.grid.2x2").foregroundStyle(prefs.accent.color)
        case .spacer:
            Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
        case .divider:
            Image(systemName: "line.diagonal").foregroundStyle(.secondary)
        case .widget:
            Image(systemName: entry.widget?.symbol ?? "square").foregroundStyle(prefs.accent.color)
        case .stack:
            Image(systemName: "square.stack.3d.up").foregroundStyle(prefs.accent.color)
        }
    }

    private func kindLabel(_ entry: DockEntry) -> String {
        switch entry.kind {
        case .app: return "App"
        case .folder: return "Folder"
        case .group: return "Group"
        case .spacer, .divider: return ""
        case .widget: return "Widget"
        case .stack: return "Scroll over it to flip"
        }
    }

    private func iconButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
    }

    private func update(_ change: (inout [DockEntry]) -> Void) {
        var copy = prefs.customDockEntries
        change(&copy)
        prefs.customDockEntries = copy
    }

    private func addApps() {
        let picked = pickApps()
        guard !picked.isEmpty else { return }
        update { $0 += picked.map(DockEntry.app) }
    }

    private func pickApps() -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        update { $0 += panel.urls.map { DockEntry.folder($0.path) } }
    }
}

private extension DockEntry {
    func renamed(_ name: String) -> DockEntry {
        var copy = self
        copy.name = name
        return copy
    }

    func withWidgets(_ widgets: [DockWidgetKind]) -> DockEntry {
        var copy = self
        copy.widgets = widgets
        return copy
    }

    func withApps(_ apps: [String]) -> DockEntry {
        var copy = self
        copy.apps = apps
        return copy
    }
}
