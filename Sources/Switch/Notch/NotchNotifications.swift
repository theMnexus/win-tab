import AppKit
import SQLite3
import SwiftUI

/// Notifications other apps posted, read from macOS's own notification store (read-only), for
/// the notch's Notifications tab and the alerts on the closed notch. The store only opens with
/// Full Disk Access; without it the tab says so and links to the setting.
@MainActor
final class NotificationFeed: ObservableObject {
    static let shared = NotificationFeed()

    struct Item: Identifiable, Equatable {
        let id: Int64
        let bundleID: String
        let title: String
        let subtitle: String
        let body: String
        let date: Date
    }

    /// One row in the tab: a sender's latest message and how many came in a row.
    struct Thread: Identifiable, Equatable {
        var id: Int64 { latest.id }
        let latest: Item
        let count: Int
    }

    enum Access: Equatable { case unknown, granted, needsFullDiskAccess }

    @Published private(set) var threads: [Thread] = []
    @Published private(set) var access: Access = .unknown
    /// Settings → Notch → Notifications.
    @Published var enabled: Bool { didSet { save(enabled, "enabled"); restart() } }
    @Published private(set) var hiddenApps: Set<String> { didSet { save(Array(hiddenApps), "hiddenApps") } }

    /// How a new notification shows on the closed notch.
    enum Popup: String, CaseIterable, Identifiable {
        case banner, compact, icon, glass, pill, vivid, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .glass: return "Glass card"
            default: return rawValue.capitalized
            }
        }
        /// Drawn by the notch island.
        var style: BatteryPreferences.NotchAlertStyle? {
            switch self {
            case .banner: return .expanded
            case .compact: return .compact
            case .icon: return .icon
            default: return nil
            }
        }
        /// Drawn as a bubble under the menu bar instead.
        var bubble: BatteryPreferences.BubbleTheme? {
            switch self {
            case .glass: return .glass
            case .pill: return .minimal
            case .vivid: return .vivid
            default: return nil
            }
        }
    }

    /// Height of the open Notifications tab.
    enum TabSize: String, CaseIterable, Identifiable {
        case standard, tall, extraTall
        var id: String { rawValue }
        var label: String { self == .extraTall ? "Extra tall" : rawValue.capitalized }
        var extra: CGFloat { self == .standard ? 0 : self == .tall ? 110 : 220 }
    }

    enum Density: String, CaseIterable, Identifiable {
        case comfortable, compact
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    static let popupDurationRange: ClosedRange<Double> = 2...10

    @Published var popup: Popup { didSet { save(popup.rawValue, "popup") } }
    @Published var popupDuration: Double { didSet { save(popupDuration, "popupDuration") } }
    /// The popup shrinks away when the pointer comes near it.
    @Published var dodgePointer: Bool { didSet { save(dodgePointer, "dodgePointer") } }
    /// Message text in popups; off shows only who it's from.
    @Published var showPreview: Bool { didSet { save(showPreview, "showPreview") } }
    /// Extra height of the open Notifications tab, set by dragging the bar at its bottom or in Settings.
    @Published var tabExtra: Double { didSet { save(tabExtra, "tabExtra") } }
    static let maxTabExtra: Double = 300
    @Published var density: Density { didSet { save(density.rawValue, "density") } }

    private static let limit = 60
    /// Only notifications this recent pop up on the notch (not a backlog after sleep).
    private static let freshFor: TimeInterval = 90
    private var items: [Item] = []
    /// Apps that sent the notifications read last, most first (for Settings' "only on the notch" list).
    @Published private(set) var recentApps: [(bundleID: String, count: Int)] = []
    private var dismissed: Set<Int64> = []
    private var clearedBefore: Date { didSet { save(clearedBefore.timeIntervalSince1970, "clearedBefore") } }
    private var lastSeenID: Int64?
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var reading = false
    /// The harness's sample notifications stay put instead of being re-read.
    private var debugFrozen = false
    /// The harness opens a row's reply bar through this.
    @Published var debugOpenRow: Int64?

    nonisolated static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: Self.key("enabled")) as? Bool ?? true
        hiddenApps = Set(d.stringArray(forKey: Self.key("hiddenApps")) ?? [])
        // Earlier builds had one on/off switch for popups.
        let oldPopup = d.object(forKey: Self.key("showOnNotch")) as? Bool
        popup = Popup(rawValue: d.string(forKey: Self.key("popup")) ?? "") ?? (oldPopup == false ? .off : .banner)
        popupDuration = d.object(forKey: Self.key("popupDuration")) as? Double ?? 5
        dodgePointer = d.object(forKey: Self.key("dodgePointer")) as? Bool ?? true
        showPreview = d.object(forKey: Self.key("showPreview")) as? Bool ?? true
        // Earlier builds had three sizes.
        let oldSize = TabSize(rawValue: d.string(forKey: Self.key("tabSize")) ?? "") ?? .tall
        tabExtra = min(d.object(forKey: Self.key("tabExtra")) as? Double ?? Double(oldSize.extra), Self.maxTabExtra)
        density = Density(rawValue: d.string(forKey: Self.key("density")) ?? "") ?? .comfortable
        clearedBefore = Date(timeIntervalSince1970: d.double(forKey: Self.key("clearedBefore")))
    }

    func start() { restart() }

    private func restart() {
        watcher?.cancel()
        watcher = nil
        guard enabled else { threads = []; return }
        reload()
        watch()
    }

    /// Re-reads when the store's write-ahead log changes (no polling); re-arms when the log is replaced.
    private func watch() {
        let fd = Darwin.open(Self.storeURL.path + "-wal", O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !source.data.isDisjoint(with: DispatchSource.FileSystemEvent([.delete, .rename])) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.restart() }
                    return
                }
                self.scheduleReload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Reads on a background queue; also called when the tab opens (e.g. after granting access).
    func reload() {
        guard enabled, !reading, !debugFrozen else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Self.read(limit: Self.limit)
            DispatchQueue.main.async { MainActor.assumeIsolated { NotificationFeed.shared.apply(result) } }
        }
    }

    private func apply(_ result: [Item]?) {
        reading = false
        guard let result else {
            access = .needsFullDiskAccess
            threads = []
            return
        }
        let firstRead = access != .granted
        access = .granted
        if firstRead && watcher == nil { watch() }
        let mine = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        items = result.filter { $0.bundleID.lowercased() != mine }
        var counts: [String: Int] = [:]
        for item in items { counts[item.bundleID, default: 0] += 1 }
        recentApps = counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
        if let last = lastSeenID { announce(items.filter { $0.id > last }) }
        lastSeenID = max(lastSeenID ?? 0, items.first?.id ?? 0)
        rebuild()
    }

    private func rebuild() {
        let shown = items.filter { !dismissed.contains($0.id) && $0.date > clearedBefore && !hiddenApps.contains($0.bundleID) }
        var out: [Thread] = []
        for item in shown {
            if let last = out.last, last.latest.bundleID == item.bundleID, last.latest.title == item.title {
                out[out.count - 1] = Thread(latest: last.latest, count: last.count + 1)
            } else {
                out.append(Thread(latest: item, count: 1))
            }
        }
        if out != threads { threads = out }
    }

    /// New ones show on the closed notch, in the chosen popup style.
    private func announce(_ fresh: [Item]) {
        guard popup != .off,
              let item = fresh.first(where: { !hiddenApps.contains($0.bundleID) && -$0.date.timeIntervalSinceNow < Self.freshFor }) else { return }
        let app = Self.appName(item.bundleID)
        let who = item.title.isEmpty ? app : NotificationText.plain(item.title)
        let more = fresh.count > 1 ? " · +\(fresh.count - 1) more" : ""
        let text = showPreview ? NotificationText.plain(item.body.isEmpty ? item.subtitle : item.body) : (item.title.isEmpty ? "New notification" : "New message from \(app)")
        // Bubbles take the accent colour (a white card would wash out); the notch stays white.
        let color = popup.bubble == nil ? Color.white : SwitchPreferences.shared.accent.color
        var alert = NotchAlert(symbol: "bell.fill", title: who, detail: text + more, color: color,
                               short: who, badge: "now", level: nil, appIcon: item.bundleID)
        alert.style = popup.style
        alert.dodges = dodgePointer
        if let theme = popup.bubble {
            BatteryAlertCenter.shared.showBubble(alert, theme: theme, duration: popupDuration)
        } else {
            _ = NotchController.current?.present(alert, duration: popupDuration)
        }
    }

    func dismiss(_ thread: Thread) {
        dismissed.formUnion(items.filter { $0.bundleID == thread.latest.bundleID && $0.title == thread.latest.title }.map(\.id))
        rebuild()
    }

    func clearAll() {
        clearedBefore = Date()
        rebuild()
    }

    func hide(app bundleID: String) {
        hiddenApps.insert(bundleID)
        rebuild()
    }

    func unhide(app bundleID: String) {
        hiddenApps.remove(bundleID)
        rebuild()
    }

    func open(_ thread: Thread) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: thread.latest.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }

    // MARK: Store

    /// The newest records, or nil when the store can't be opened (no Full Disk Access).
    nonisolated static func read(limit: Int) -> [Item]? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        let sql = "SELECT r.rec_id, a.identifier, r.data FROM record r JOIN app a ON a.app_id = r.app_id ORDER BY r.delivered_date DESC LIMIT \(limit)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("win-tab: notification store: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var items: [Item] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let app = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            guard let bytes = sqlite3_column_blob(statement, 2) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
            if let item = parse(id: id, app: app, data: data) { items.append(item) }
        }
        return items
    }

    /// A record's plist: {app, date (seconds since 2001), req: {titl, subt, body}}.
    nonisolated static func parse(id: Int64, app: String, data: Data) -> Item? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let req = plist["req"] as? [String: Any] else { return nil }
        let title = req["titl"] as? String ?? "", subtitle = req["subt"] as? String ?? "", body = req["body"] as? String ?? ""
        guard !(title + subtitle + body).isEmpty else { return nil }
        let date = (plist["date"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) } ?? Date()
        return Item(id: id, bundleID: plist["app"] as? String ?? app, title: title, subtitle: subtitle, body: body, date: date)
    }

    private static func key(_ name: String) -> String { "switch.notifications." + name }
    private func save(_ value: Any, _ name: String) { UserDefaults.standard.set(value, forKey: Self.key(name)) }

    #if DEBUG
    /// Sample notifications for screenshots (the harness), then a live one on the notch.
    func debugInject() {
        let now = Date()
        let sample = [
            Item(id: 9_000_003, bundleID: "com.apple.MobileSMS", title: "Mia Chen", subtitle: "", body: "Dinner at 8? I found a tiny Italian place 🍝", date: now),
            Item(id: 9_000_002, bundleID: "ru.keepcoder.Telegram", title: "Sam Rivera", subtitle: "", body: "Look at the notch 👀", date: now.addingTimeInterval(-40)),
            Item(id: 9_000_001, bundleID: "ru.keepcoder.Telegram", title: "Sam Rivera", subtitle: "", body: "Are you there?", date: now.addingTimeInterval(-60)),
            Item(id: 9_000_000, bundleID: "com.apple.mail", title: "Lena Park", subtitle: "", body: "**Standup** moved to `3 pm` — see _agenda_", date: now.addingTimeInterval(-600)),
        ]
        debugFrozen = true
        access = .granted
        items = sample
        recentApps = [("ru.keepcoder.Telegram", 2), ("com.apple.MobileSMS", 1), ("com.vng.zalo", 1), ("com.apple.mail", 1)]
        lastSeenID = 9_000_002
        rebuild()
        announce([sample[0]])
    }

    static func selfCheck() -> [String] {
        let plist: [String: Any] = ["app": "com.example.chat", "date": 800_000_000.0, "req": ["titl": "Mia", "body": "Dinner at 8?"]]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
              let item = parse(id: 7, app: "x", data: data) else { return ["notifications: record didn't parse"] }
        var failures: [String] = []
        if item.bundleID != "com.example.chat" || item.title != "Mia" || item.body != "Dinner at 8?" { failures.append("notifications: fields \(item)") }
        if abs(item.date.timeIntervalSinceReferenceDate - 800_000_000) > 1 { failures.append("notifications: date epoch") }
        let empty = try? PropertyListSerialization.data(fromPropertyList: ["req": [String: Any]()], format: .binary, options: 0)
        if empty.flatMap({ parse(id: 1, app: "a", data: $0) }) != nil { failures.append("notifications: empty record kept") }
        if NotificationText.plain("**Build** failed on `main`") != "Build failed on main" { failures.append("notifications: markdown plain") }
        if NotificationText.plain("5 * 3 = 15, a_b") != "5 * 3 = 15, a_b" { failures.append("notifications: stray marks kept") }
        if NotificationReply.quoted(#"say "hi" \ bye"#) != #""say \"hi\" \\ bye""# { failures.append("notifications: AppleScript quoting") }
        if !NotificationReply.canSendDirectly("com.apple.MobileSMS") || NotificationReply.canSendDirectly("ru.keepcoder.telegram") {
            failures.append("notifications: direct-send apps")
        }
        return failures
    }
    #endif
}

// MARK: - Markdown

/// Notification text as apps send it can carry Markdown (**bold**, _italics_, `code`, links);
/// shown formatted instead of with the raw marks.
enum NotificationText {
    static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// The text without its marks, for one-line popups.
    static func plain(_ text: String) -> String { String(formatted(text).characters) }
}

// MARK: - Replies

/// Sending a reply or a reaction. Messages takes it directly (AppleScript, to the chat whose
/// person matches the sender's name); other apps don't let anyone send for them, so the text is
/// copied and the app opened on top, ready to paste.
enum NotificationReply {
    static let reactions = ["😂", "❤️", "🥹", "🙏", "😮", "👍"]
    private static let messagesIDs: Set<String> = ["com.apple.mobilesms", "com.apple.ichat"]
    private static let queue = DispatchQueue(label: "win-tab.reply")

    enum Outcome: Equatable {
        case sent(String)
        case copied(String)
        case failed(String)

        var message: String {
            switch self {
            case .sent(let who): return "Sent to \(who)"
            case .copied(let app): return "Copied: paste it in \(app) with ⌘V"
            case .failed(let why): return why
            }
        }
    }

    static func canSendDirectly(_ bundleID: String) -> Bool { messagesIDs.contains(bundleID.lowercased()) }

    @MainActor
    static func send(_ text: String, to item: NotificationFeed.Item, done: @escaping (Outcome) -> Void) {
        let app = NotificationFeed.appName(item.bundleID)
        guard canSendDirectly(item.bundleID), !item.title.isEmpty else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            done(.copied(app))
            return
        }
        let who = item.title
        queue.async {
            let result = runMessagesScript(to: who, text: text)
            DispatchQueue.main.async { done(result) }
        }
    }

    /// AppleScript string literal.
    nonisolated static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    nonisolated private static func runMessagesScript(to who: String, text: String) -> Outcome {
        let source = """
        tell application "Messages"
            repeat with c in chats
                try
                    if name of c is \(quoted(who)) then
                        send \(quoted(text)) to c
                        return "ok"
                    end if
                end try
                try
                    set ps to participants of c
                    if (count of ps) is 1 and full name of item 1 of ps is \(quoted(who)) then
                        send \(quoted(text)) to c
                        return "ok"
                    end if
                end try
            end repeat
        end tell
        return "notfound"
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("win-tab: Messages reply failed: \(error)")
            return .failed((error[NSAppleScript.errorNumber] as? Int) == -1743
                           ? "Allow win-tab to control Messages in Privacy & Security → Automation"
                           : "Couldn't send: \(error[NSAppleScript.errorMessage] as? String ?? "Messages error")")
        }
        return result?.stringValue == "ok" ? .sent(who) : .failed("No chat with \(who) in Messages")
    }
}

// MARK: - Tab

/// The notch's Notifications tab: recent notifications, newest first, one row per sender; click
/// a row to react or reply.
struct NotchNotificationsView: View {
    @ObservedObject var state: NotchState
    @ObservedObject private var feed = NotificationFeed.shared
    @State private var openRow: Int64?
    @State private var toast: String?

    var body: some View {
        Group {
            if !feed.enabled {
                VStack(spacing: 8) {
                    placeholder("bell.slash", "Notifications are off", "Nothing shows on the notch until you turn them back on.")
                    Button("Turn on") { feed.enabled = true }.controlSize(.small)
                }
            } else if feed.access == .needsFullDiskAccess {
                VStack(spacing: 8) {
                    placeholder("lock.shield", "Allow Full Disk Access", "macOS keeps notifications private; win-tab reads them only on this Mac.")
                    Button("Open Privacy Settings") { NotificationFeed.openFullDiskAccessSettings() }.controlSize(.small)
                }
            } else if feed.threads.isEmpty {
                placeholder("bell", "No notifications", "New ones show up here and on the notch.")
            } else {
                list
            }
        }
        .overlay(alignment: .bottom) {
            NotchResizeHandle(state: state, extra: $feed.tabExtra, maxExtra: NotificationFeed.maxTabExtra, defaultExtra: 110).offset(y: 12)
        }
        .onAppear { feed.reload() }
        .onChange(of: openRow) { _, row in state.replying = row != nil }
        .onReceive(feed.$debugOpenRow) { row in if let row { openRow = row } }
        .onChange(of: state.expanded) { _, open in if !open { openRow = nil } }
    }

    private var list: some View {
        VStack(spacing: 4) {
            HStack {
                if let toast {
                    Label(toast, systemImage: "checkmark.circle.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.green)
                        .lineLimit(1).transition(.opacity)
                } else {
                    Text("\(feed.threads.count) recent").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Button("Clear") { withAnimation(.easeOut(duration: 0.2)) { openRow = nil; feed.clearAll() } }
                    .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(feed.threads.enumerated()), id: \.element.id) { index, thread in
                            if index > 0 { Divider().overlay(Color.white.opacity(0.08)).padding(.leading, feed.density == .compact ? 38 : 50) }
                            NotificationRow(thread: thread, open: openRow == thread.id,
                                            toggle: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { openRow = openRow == thread.id ? nil : thread.id } },
                                            sent: { show($0) })
                                .id(thread.id)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                    .padding(.bottom, 14)
                }
                .onChange(of: openRow) { _, row in
                    if let row { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(row, anchor: .top) } }
                }
            }
            // Rows fade out at the bottom edge rather than being cut off.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }

    private func show(_ outcome: NotificationReply.Outcome) {
        withAnimation(.easeOut(duration: 0.2)) {
            toast = outcome.message
            if case .failed = outcome {} else { openRow = nil }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation(.easeOut(duration: 0.3)) { toast = nil } }
    }

    private func placeholder(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Avatar with the app's icon on it, sender, message, time and count; click to react or reply.
private struct NotificationRow: View {
    let thread: NotificationFeed.Thread
    let open: Bool
    let toggle: () -> Void
    let sent: (NotificationReply.Outcome) -> Void
    @ObservedObject private var feed = NotificationFeed.shared
    @State private var hovering = false

    var body: some View {
        let item = thread.latest
        let name = item.title.isEmpty ? NotificationFeed.appName(item.bundleID) : NotificationText.plain(item.title)
        let compact = feed.density == .compact && !open
        VStack(spacing: 8) {
            HStack(spacing: compact ? 9 : 12) {
                Avatar(name: name, bundleID: item.bundleID, size: compact ? 24 : 38)
                if compact {
                    // One line: sender, then the message.
                    (Text(name).font(.system(size: 12, weight: .semibold)) + Text("  ") + Text(NotificationText.formatted(item.body.isEmpty ? item.subtitle : item.body))
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.7)))
                        .lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(NotificationText.formatted(item.body.isEmpty ? item.subtitle : item.body))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(open ? 4 : 1)
                    }
                }
                Spacer(minLength: 6)
                if hovering && !open {
                    Button { withAnimation(.easeOut(duration: 0.2)) { feed.dismiss(thread) } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 22)
                            .background(Circle().fill(.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: 6) {
                        if thread.count > 1 {
                            Text("\(thread.count)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(Color(red: 0.95, green: 0.35, blue: 0.3)))
                        }
                        Text(Self.age(item.date)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if open {
                ReplyBar(item: item, sent: sent, close: toggle)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, compact ? 3 : 6).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(open ? 0.06 : hovering ? 0.05 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .contextMenu {
            Button("Open \(NotificationFeed.appName(item.bundleID))") { feed.open(thread) }
            Button("Dismiss") { feed.dismiss(thread) }
            Divider()
            Button("Hide Notifications from \(NotificationFeed.appName(item.bundleID))") { feed.hide(app: item.bundleID) }
        }
    }

    /// "now", "5m", "2h", "3d".
    static func age(_ date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSinceNow))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        return s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
    }
}

/// Reactions in a capsule, then a reply field; Messages gets them directly, other apps via paste.
private struct ReplyBar: View {
    let item: NotificationFeed.Item
    let sent: (NotificationReply.Outcome) -> Void
    let close: () -> Void
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var direct: Bool { NotificationReply.canSendDirectly(item.bundleID) }

    var body: some View {
        // One row, so an open reply fits the notch without scrolling the sender away.
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(NotificationReply.reactions, id: \.self) { emoji in
                    ReactionButton(emoji: emoji) { send(emoji) }
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Capsule().fill(.white.opacity(0.1)))
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
            TextField(direct ? "Reply to \(item.title)…" : "Reply… (copied, then \(NotificationFeed.appName(item.bundleID)) opens)", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.1)))
                .focused($focused)
                .onSubmit { send(text) }
                .onExitCommand(perform: close)
            Button { send(text) } label: {
                Image(systemName: sending ? "ellipsis" : "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(text.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.3) : Color.white))
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            .help(direct ? "Send" : "Copy and open \(NotificationFeed.appName(item.bundleID))")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 28, height: 28)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.leading, 50)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
    }

    private func send(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        sending = true
        NotificationReply.send(trimmed, to: item) { outcome in
            sending = false
            if case .failed = outcome {} else { text = "" }
            sent(outcome)
        }
    }
}

private struct ReactionButton: View {
    let emoji: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji).font(.system(size: 16))
                .frame(width: 27, height: 26)
                .scaleEffect(hovering ? 1.3 : 1)
                .offset(y: hovering ? -2 : 0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Initials on a colour picked from the name, with the app's icon in the corner.
private struct Avatar: View {
    let name: String
    let bundleID: String
    var size: CGFloat = 38

    private var initials: String {
        name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// Same name, same colour, every launch (`hashValue` changes per process).
    private var color: Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) &* 31 }
        return Color(hue: Double(abs(sum) % 360) / 360, saturation: 0.35, brightness: 0.55)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                .overlay(Text(initials.isEmpty ? "•" : initials).font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(.white))
                .frame(width: size, height: size)
            if let icon = AppIcons.icon(bundleID: bundleID) {
                Image(nsImage: icon).resizable().frame(width: size * 0.45, height: size * 0.45)
                    .background(Circle().fill(.black).frame(width: size * 0.5, height: size * 0.5))
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
    }
}
