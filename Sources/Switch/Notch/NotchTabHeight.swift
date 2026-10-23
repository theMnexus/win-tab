import AppKit
import SwiftUI

/// Extra height of tabs that grow with a drag bar, beyond the island's usual content height.
/// The Notifications tab keeps its own (`NotificationFeed.tabExtra`).
@MainActor
final class NotchTabHeights: ObservableObject {
    static let shared = NotchTabHeights()
    static let maxExtra: Double = 300
    static let filesDefault: Double = 60
    static let translateDefault: Double = 120
    private static let filesKey = "switch.notch.files.extra"
    private static let translateKey = "switch.notch.translate.extra"

    @Published var files: Double { didSet { UserDefaults.standard.set(files, forKey: Self.filesKey) } }
    @Published var translate: Double { didSet { UserDefaults.standard.set(translate, forKey: Self.translateKey) } }

    private init() {
        let d = UserDefaults.standard
        files = min(d.object(forKey: Self.filesKey) as? Double ?? Self.filesDefault, Self.maxExtra)
        translate = min(d.object(forKey: Self.translateKey) as? Double ?? Self.translateDefault, Self.maxExtra)
    }
}

/// The bar at the bottom of a tab: drag it to make the tab taller or shorter; double-click
/// for the default height.
struct NotchResizeHandle: View {
    @ObservedObject var state: NotchState
    @Binding var extra: Double
    let maxExtra: Double
    let defaultExtra: Double
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        let active = hovering || start != nil
        Capsule().fill(.white.opacity(active ? 0.6 : 0.22))
            .frame(width: active ? 56 : 40, height: 5)
            .frame(width: 140, height: 18)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
            .onHover { h in
                hovering = h
                if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil {
                        start = extra
                        state.resizing = true
                    }
                    extra = min(max((start ?? 0) + v.translation.height, 0), maxExtra)
                    // Outline and content in the same frame: the bar stays under the pointer.
                    state.onResize?()
                }
                .onEnded { _ in
                    start = nil
                    state.resizing = false
                })
            .onTapGesture(count: 2) { withAnimation { extra = defaultExtra } }
            .help("Drag to resize · double-click for the default height")
    }
}
