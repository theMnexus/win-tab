import SwiftUI

/// Building blocks shared by the Settings tabs: titled sections, cards, and rows with a
/// toggle, slider or segmented picker, all following the accent colour.
struct SettingsSection<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let content: Content
    @ObservedObject private var prefs = SwitchPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(prefs.accent.color).frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .settingsSearchable(title, detail: subtitle)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
            )
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .settingsSearchable(title, detail: detail)
    }
}

struct SettingsToggle: View {
    let title: String
    var detail: String = ""
    @Binding var isOn: Bool
    @ObservedObject private var prefs = SwitchPreferences.shared

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(prefs.accent.color)
        }
    }
}

struct SettingsSlider: View {
    let title: String
    let value: String
    @Binding var number: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    @ObservedObject private var prefs = SwitchPreferences.shared

    var body: some View {
        SettingsRow(title: title, detail: value) {
            Slider(value: $number, in: range, step: step).frame(width: 220).tint(prefs.accent.color)
        }
    }
}

struct SettingsSegmented<Value: Hashable & Identifiable>: View {
    let title: String
    var detail: String = ""
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var width: CGFloat = 260

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Picker("", selection: $selection) {
                ForEach(options) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: width)
        }
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().opacity(0.4).padding(.leading, 16) }
}

/// A list of short words as removable chips, with a field to add one (Return or Add).
struct SettingsTokens: View {
    let title: String
    var detail: String = ""
    @Binding var items: [String]
    var placeholder = "Add…"
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 5) {
                        Text(item).font(.system(size: 12, design: .monospaced))
                        Button { items.removeAll { $0 == item } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove \(item)")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)))
                }
                HStack(spacing: 4) {
                    TextField(placeholder, text: $draft).textFieldStyle(.roundedBorder).frame(width: 130).onSubmit(add)
                    Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSearchable(title, detail: detail)
    }

    private func add() {
        let word = draft.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        if !items.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { items.append(word) }
        draft = ""
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let gap: CGFloat = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
