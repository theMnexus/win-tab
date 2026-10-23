import AppKit
import SwiftUI

/// One searchable setting: its row title and detail, and the tab it lives on.
struct SettingsHit: Hashable {
    let title: String
    let detail: String
    let tab: String

    /// Every word of the query found in the title, detail or tab name, ignoring case and accents.
    func matches(_ query: String, tabLabel: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }
        let haystack = "\(title) \(detail) \(tabLabel)"
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Rows report themselves up the view tree, so Settings can search tabs it isn't showing.
struct SettingsHitsKey: PreferenceKey {
    static let defaultValue: [SettingsHit] = []
    static func reduce(value: inout [SettingsHit], nextValue: () -> [SettingsHit]) { value += nextValue() }
}

extension EnvironmentValues {
    /// The tab a row is drawn in.
    @Entry var settingsTab: String = ""
    /// Title of the row a search result just opened; it lights up and scrolls into view.
    @Entry var settingsHighlight: String?
}

extension View {
    /// Makes a settings row findable from the search field, and highlights it when picked there.
    func settingsSearchable(_ title: String, detail: String = "") -> some View {
        modifier(SettingsSearchable(title: title, detail: detail))
    }
}

private struct SettingsSearchable: ViewModifier {
    let title: String
    let detail: String
    @Environment(\.settingsTab) private var tab
    @Environment(\.settingsHighlight) private var highlight
    @ObservedObject private var prefs = SwitchPreferences.shared

    func body(content: Content) -> some View {
        let lit = highlight == title
        content
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prefs.accent.color.opacity(lit ? 0.2 : 0))
                    .animation(.easeOut(duration: 0.35), value: lit)
                    .background { if lit { ScrollIntoView() } }
            }
            // Added to what the rows inside report (a section holds rows), not replacing it.
            .transformPreference(SettingsHitsKey.self) { hits in
                if !tab.isEmpty { hits.append(SettingsHit(title: title, detail: detail, tab: tab)) }
            }
    }
}

/// Scrolls the enclosing scroll view so this spot is visible.
private struct ScrollIntoView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -40)) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
