import SwiftUI

/// Settings → Notch → Closed notch layout: a preview of the closed notch and three rows (Left,
/// Right, Hidden). Drag chips between rows or onto another chip to reorder; the arrows, + and ×
/// do the same without dragging.
struct NotchLayoutEditor: View {
    @ObservedObject private var prefs = SwitchPreferences.shared

    private enum Row { case left, right, hidden }

    private static let items: [String: (title: String, symbol: String)] = [
        "artwork": ("Artwork", "music.note"),
        "bars": ("Bars", "waveform"),
        "time": ("Time", "clock"),
        "date": ("Date", "calendar"),
        "wifi": ("Wi-Fi", "wifi"),
        "battery": ("Battery", "battery.75"),
    ]

    private var hidden: [String] {
        SwitchPreferences.notchItemKeys.filter { !prefs.notchLeftItems.contains($0) && !prefs.notchRightItems.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview
            row(.left, "Left of the notch", prefs.notchLeftItems)
            row(.right, "Right of the notch", prefs.notchRightItems)
            row(.hidden, "Hidden", hidden)
            Text("Drag to move or reorder. Artwork and Bars show the song or timer and stay empty when nothing plays.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    // MARK: Preview

    private var preview: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) { ForEach(prefs.notchLeftItems, id: \.self) { sample($0) } }
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.black.frame(width: 110)
            HStack(spacing: 7) { ForEach(prefs.notchRightItems, id: \.self) { sample($0) } }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(width: 400, height: 30)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Color.black))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.14, green: 0.14, blue: 0.3), Color(red: 0.4, green: 0.24, blue: 0.4)],
                                 startPoint: .leading, endPoint: .trailing)))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: prefs.notchLeftItems)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: prefs.notchRightItems)
    }

    @ViewBuilder
    private func sample(_ key: String) -> some View {
        let font = Font.system(size: 10.5, weight: .semibold, design: .rounded)
        switch key {
        case "artwork":
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
                .frame(width: 18, height: 18)
        case "bars":
            HStack(spacing: 1.5) {
                ForEach(Array([6.0, 10, 5, 8].enumerated()), id: \.offset) { Capsule().fill(Color.orange).frame(width: 2, height: $0.element) }
            }
        case "time": Text("15:11").font(font)
        case "date": Text("Mon 28").font(font).foregroundStyle(.white.opacity(0.7))
        case "wifi": Image(systemName: "wifi").font(.system(size: 10, weight: .semibold))
        case "battery":
            HStack(spacing: 2) {
                Text("64%").font(font)
                BatteryGlyph(percent: 64, color: .white.opacity(0.85), showsPercent: false, height: 9)
            }
        default: EmptyView()
        }
    }

    // MARK: Rows

    private func row(_ row: Row, _ title: String, _ keys: [String]) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12, weight: .medium)).frame(width: 118, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    chip(key, in: row)
                        .dropDestination(for: String.self) { dropped, _ in
                            guard let moved = dropped.first else { return false }
                            place(moved, in: row, before: key)
                            return true
                        }
                }
                if keys.isEmpty {
                    Text(row == .hidden ? "Nothing hidden" : "Drop items here").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08)))
            .dropDestination(for: String.self) { dropped, _ in
                guard let moved = dropped.first else { return false }
                place(moved, in: row, before: nil)
                return true
            }
        }
    }

    private func chip(_ key: String, in row: Row) -> some View {
        let item = Self.items[key] ?? (key, "questionmark")
        let tint = row == .hidden ? Color.primary.opacity(0.08) : prefs.accent.color.opacity(0.22)
        return HStack(spacing: 5) {
            if row == .right { button("chevron.left", "Move left") { place(key, in: .left, before: nil) } }
            Label(item.title, systemImage: item.symbol).font(.system(size: 11, weight: .medium))
            if row == .left { button("chevron.right", "Move right") { place(key, in: .right, before: nil) } }
            if row == .hidden {
                button("plus", "Show") { place(key, in: ["time", "date", "artwork"].contains(key) ? .left : .right, before: nil) }
            } else {
                button("xmark", "Hide") { place(key, in: .hidden, before: nil) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(tint))
        .foregroundStyle(row == .hidden ? .secondary : .primary)
        .draggable(key)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).frame(width: 12, height: 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    /// Moves `key` into `row`, before `before` (or at the end).
    private func place(_ key: String, in row: Row, before: String?) {
        guard SwitchPreferences.notchItemKeys.contains(key), key != before else { return }
        var left = prefs.notchLeftItems.filter { $0 != key }
        var right = prefs.notchRightItems.filter { $0 != key }
        func insert(_ list: inout [String]) {
            if let before, let i = list.firstIndex(of: before) { list.insert(key, at: i) } else { list.append(key) }
        }
        switch row {
        case .left: insert(&left)
        case .right: insert(&right)
        case .hidden: break
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            prefs.notchLeftItems = left
            prefs.notchRightItems = right
        }
    }
}
