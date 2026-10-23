import SwiftUI

/// Shared surfaces for the notch tabs (Files, Translate): cards, chips, menus and segmented
/// pickers, so every tab has the same depth, spacing and hover states.
enum NotchInk {
    static let card = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.09)
    static let chip = Color.white.opacity(0.09)
    static let chipHover = Color.white.opacity(0.17)
    static let label = Color.white.opacity(0.45)
    static let radius: CGFloat = 12
}

/// A rounded panel that groups one feature. `grows` fills the height it's given.
struct NotchCard<Content: View>: View {
    var grows = false
    var padding: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: grows ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: NotchInk.radius, style: .continuous).fill(NotchInk.card))
            .overlay(RoundedRectangle(cornerRadius: NotchInk.radius, style: .continuous).strokeBorder(NotchInk.cardStroke, lineWidth: 0.5))
    }
}

/// A card's title row: a tinted symbol, an uppercase name, then its controls on the right.
struct NotchCardHeader<Trailing: View>: View {
    let title: String
    var symbol: String?
    var tint: Color = .white
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint) }
            NotchLabel(title)
            if let detail { Text(detail).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.35)).lineLimit(1) }
            Spacer(minLength: 4)
            trailing
        }
        .frame(height: 18)
    }
}

extension NotchCardHeader where Trailing == EmptyView {
    init(title: String, symbol: String? = nil, tint: Color = .white, detail: String? = nil) {
        self.init(title: title, symbol: symbol, tint: tint, detail: detail) { EmptyView() }
    }
}

struct NotchLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(NotchInk.label).lineLimit(1)
    }
}

/// A capsule button: icon and/or title. `quiet` shows its fill only on hover (for card headers);
/// `prominent` is the one main action (white with dark text).
struct NotchChip: View {
    var title: String?
    var symbol: String?
    var tint: Color?
    var quiet = false
    var prominent = false
    var help: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(prominent ? Color.black : tint ?? .white)
                }
                if let title { Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1) }
            }
            .foregroundStyle(prominent ? Color.black : .white)
            .padding(.horizontal, title == nil ? 0 : 8)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(help ?? title ?? "")
    }

    private var fill: Color {
        if prominent { return .white.opacity(hovering ? 1 : 0.88) }
        if quiet { return hovering ? NotchInk.chip : .clear }
        return hovering ? NotchInk.chipHover : NotchInk.chip
    }
}

/// A chip that opens a menu. The label is one Text (menus on macOS drop richer labels).
struct NotchMenuChip<Items: View>: View {
    let title: String
    var quiet = false
    @ViewBuilder var items: Items
    @State private var hovering = false

    var body: some View {
        Menu { items } label: {
            Text(title + "  ▾").font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(quiet && !hovering ? .clear : hovering ? NotchInk.chipHover : NotchInk.chip))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// One choice out of a few (US/UK, speeds, Translate/Phrase book); the knob slides between them.
struct NotchSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value
    let pick: (Value) -> Void
    @Namespace private var knob

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let on = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { pick(option.value) }
                } label: {
                    Text(option.label).font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(on ? Color.black : .white.opacity(0.7))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background {
                            if on { Capsule().fill(.white.opacity(0.9)).matchedGeometryEffect(id: "knob", in: knob) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(option.label)
            }
        }
        .padding(2)
        .background(Capsule().fill(NotchInk.chip))
    }
}
