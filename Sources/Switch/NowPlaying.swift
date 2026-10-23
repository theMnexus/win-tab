import AppKit
import AudioToolbox
import CoreAudio
import CoreImage
import SwiftUI

/// Whatever is playing on the Mac — Chrome/YouTube, Safari, Spotify, Music, any app that reports
/// to the system's Now Playing — read through the bundled MediaRemoteAdapter (see
/// Vendor/MediaRemoteAdapter). macOS 15.4+ closes MediaRemote to third-party apps; the adapter
/// runs under `/usr/bin/perl`, which is allowed, and streams JSON lines. If the adapter can't
/// run, it falls back to asking Music and Spotify over AppleScript.
///
/// The system reports one player at a time, so `sources` also lists every app that is making
/// sound (CoreAudio) plus running Spotify/Music; pick one with `select` and `track`, the
/// controls and the artwork follow it. Spotify and Music are driven over AppleScript, other
/// browsers through JavaScript sent over AppleScript, anything else can only be brought forward.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    struct Track: Equatable {
        var title: String
        var artist: String
        var playing: Bool
        /// App name, e.g. "Google Chrome".
        var player: String
        var bundleID: String
        var duration: Double = 0
        /// Elapsed seconds as of `elapsedAt`.
        var elapsed: Double = 0
        var elapsedAt = Date()

        /// Live position: advances on its own while playing, no polling needed.
        func position(at now: Date = Date()) -> Double {
            let p = playing ? elapsed + now.timeIntervalSince(elapsedAt) : elapsed
            return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
        }
    }

    /// An app that has something playing (or could: Spotify and Music while open).
    struct Source: Identifiable, Equatable {
        let bundleID: String
        let name: String
        /// Making sound right now.
        var audible: Bool
        /// The player the system's Now Playing reports: full info and controls.
        var isSystem: Bool
        var id: String { bundleID }
    }

    enum Command {
        case playpause, next, previous
        var adapterID: String {
            switch self {
            case .playpause: return "2"
            case .next: return "4"
            case .previous: return "5"
            }
        }
        var appleScript: String {
            switch self {
            case .playpause: return "playpause"
            case .next: return "next track"
            case .previous: return "previous track"
            }
        }
    }

    /// What the notch and widgets show: the chosen source, or the system's player.
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    /// A vivid colour taken from the artwork, for tinting the notch and widgets.
    @Published private(set) var tint: Color?
    @Published private(set) var sources: [Source] = []
    /// nil follows the system's player.
    @Published private(set) var selectedID: String?
    /// Why the last browser command did nothing (JavaScript from Apple Events off, or win-tab not
    /// allowed to control the browser), shown for a few seconds.
    @Published private(set) var browserHint: BrowserHint?

    struct BrowserHint: Equatable {
        let text: String
        /// System Settings › Privacy & Security › Automation, when that's what's missing.
        let opensAutomation: Bool
    }

    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Controls work for the shown source (only bringing it forward for apps we can't drive).
    var canControl: Bool {
        guard let id = track?.bundleID else { return false }
        return id == systemTrack?.bundleID || Self.scriptPlayers[id] != nil || Self.browsers[id] != nil
    }
    var canSeek: Bool { adapter != nil && track?.bundleID == systemTrack?.bundleID && (track?.duration ?? 0) > 0 }

    private var systemTrack: Track?
    private var systemArtwork: NSImage?
    private var systemTint: Color?
    private var scriptTracks: [String: Track] = [:]
    /// Title of the media tab in browsers that aren't the system's player.
    private var tabTitles: [String: String] = [:]
    private var audibleIDs: [String] = []

    private var consumers: Set<String> = []
    private var adapter: AdapterStream?
    private var adapterFailures = 0
    private static let maxAdapterFailures = 3
    private let scriptQueue = DispatchQueue(label: "win-tab.nowplaying.script")
    private var sourceTimer: Timer?
    private static let sourceInterval: TimeInterval = 1.5
    private var scriptPollTick = 0

    private var running = false
    private var sourcesWanted = false

    /// The Dock and the notch each switch it on for themselves; it runs while either wants it.
    func setActive(_ active: Bool, for consumer: String) {
        if active { consumers.insert(consumer) } else { consumers.remove(consumer) }
        if consumers.isEmpty { stop() } else if !running { start() }
    }

    /// The list of playing apps is only on screen while the notch is open: scan for it then,
    /// and rely on the adapter's pushed updates the rest of the time.
    func setSourcesVisible(_ visible: Bool) {
        sourcesWanted = visible
        updateSourceTimer()
        if visible { resync() }
    }

    /// Checks the stream against a one-off read (38 ms) whenever the notch opens: a stream that
    /// stopped hearing from MediaRemote keeps showing an old song, or nothing, until restarted.
    private func resync() {
        guard running, adapter != nil else { return }
        AdapterStream.read { [weak self] state in
            guard let self, self.running, let state else { return }
            let title = state["title"] as? String ?? ""
            let current = self.systemTrack
            let same = title.isEmpty ? current == nil
                : current?.title == title && current?.bundleID == state["bundleIdentifier"] as? String
                  && current?.playing == (state["playing"] as? Bool ?? false)
            guard !same else { return }
            self.adapter?.stop()
            self.adapter = nil
            self.startAdapter()
        }
    }

    private func updateSourceTimer() {
        // Without the adapter, polling Spotify/Music is the only source, so it always runs.
        let want = running && (sourcesWanted || adapter == nil)
        if want && sourceTimer == nil {
            pollSources()
            sourceTimer = Timer.scheduledTimer(withTimeInterval: Self.sourceInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollSources() }
            }
        } else if !want {
            sourceTimer?.invalidate()
            sourceTimer = nil
        }
    }

    private func start() {
        running = true
        startAdapter()
        updateSourceTimer()
    }

    /// Stops the adapter process; call on quit, or it outlives win-tab until its next write.
    func shutdown() { stop() }

    private func startAdapter() {
        guard adapterFailures < Self.maxAdapterFailures else { return }
        AdapterStream.killOrphans()
        adapter = AdapterStream(onPayload: { [weak self] in self?.apply($0) }, onExit: { [weak self] in self?.adapterExited() })
    }

    private func stop() {
        running = false
        adapter?.stop()
        adapter = nil
        sourceTimer?.invalidate()
        sourceTimer = nil
    }

    private func adapterExited() {
        adapter = nil
        updateSourceTimer()
        adapterFailures += 1
        NSLog("win-tab: now playing adapter exited (\(adapterFailures)/\(Self.maxAdapterFailures))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.consumers.isEmpty, self.adapter == nil else { return }
            self.startAdapter()
        }
    }

    // MARK: - Choosing a source

    func select(_ id: String?) {
        selectedID = id == autoID ? nil : id
        browserHint = nil
        refreshShown()
    }

    /// Without a choice: the system's player while it plays, else whatever is making sound
    /// (a paused Music shouldn't hide a playing YouTube tab), else the system's player.
    private var autoID: String? {
        if systemTrack?.playing == true { return systemTrack?.bundleID }
        if let t = scriptTracks.values.first(where: \.playing) { return t.bundleID }
        return sources.first(where: \.audible)?.bundleID ?? systemTrack?.bundleID
    }

    /// Sources making sound or playing at the last refresh, to spot one that just started.
    private var activeIDs: Set<String> = []

    private func isActive(_ id: String) -> Bool {
        audibleIDs.contains(id) || (systemTrack?.bundleID == id && systemTrack?.playing == true) || scriptTracks[id]?.playing == true
    }

    private func refreshShown() {
        let nowActive = Set(sources.map(\.bundleID).filter(isActive))
        // Something just started playing while the chosen player is quiet: show what you hear.
        if let chosen = selectedID, !isActive(chosen), let started = nowActive.subtracting(activeIDs).sorted().first {
            selectedID = started == autoID ? nil : started
        }
        activeIDs = nowActive
        let id = selectedID ?? autoID
        var shown: Track?
        if let id, id == systemTrack?.bundleID {
            shown = systemTrack
        } else if let id, let t = scriptTracks[id] {
            shown = t
        } else if let id, let source = sources.first(where: { $0.bundleID == id }) {
            let title = tabTitles[id] ?? (source.audible ? "Playing audio" : "Paused")
            shown = Track(title: title, artist: "", playing: source.audible, player: source.name, bundleID: id)
        } else if selectedID != nil {
            // The chosen app went quiet and closed: follow the system again.
            selectedID = nil
            shown = systemTrack
        } else {
            shown = systemTrack ?? scriptTracks.values.first { $0.playing } ?? scriptTracks.values.first
        }
        if shown?.bundleID != track?.bundleID || shown?.title != track?.title { browserHint = nil }
        if shown != track { track = shown }
        let isSystem = shown != nil && shown?.bundleID == systemTrack?.bundleID
        let art = isSystem ? systemArtwork : nil
        if art !== artwork { artwork = art }
        let t = isSystem ? systemTint : nil
        if t != tint { tint = t }
    }

    // MARK: - Commands

    /// A short note under the controls ("No next track on this page"), cleared after a moment.
    @Published private(set) var controlHint: String?

    func send(_ command: Command) {
        guard let shown = track else { return }
        let id = shown.bundleID
        if id == systemTrack?.bundleID, adapter != nil {
            // Previous a few seconds in restarts the track, like every player; always works.
            if command == .previous, shown.position() > Self.restartAfter {
                seek(to: 0)
                return
            }
            AdapterStream.run(["send", command.adapterID])
            // A web page only skips if it registered next/previous with the browser (a long mix
            // usually hasn't): if nothing changed, click the page's own button or restart.
            if command != .playpause, let browser = Self.browsers[id] { verifySkip(command, from: shown, browser: browser) }
        } else if let name = Self.scriptPlayers[id] {
            scriptQueue.async { _ = Self.runScript("tell application \"\(name)\" to \(command.appleScript)") }
        } else if let browser = Self.browsers[id] {
            runBrowser(browser, command: command)
        } else {
            openPlayer()
            return
        }
        // Reflect play/pause at once; the next update confirms it.
        if command == .playpause {
            var t = shown
            t.elapsed = t.position()
            t.elapsedAt = Date()
            t.playing.toggle()
            if id == systemTrack?.bundleID { systemTrack = t } else { scriptTracks[id] = t }
            track = t
        }
    }

    private static let restartAfter: TimeInterval = 3
    private static let skipCheckDelay: TimeInterval = 1.5

    private func verifySkip(_ command: Command, from before: Track, browser: Browser) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.skipCheckDelay) { [weak self] in
            guard let self, let now = self.track, now.bundleID == before.bundleID else { return }
            // A new title, or back near the start, means the skip happened.
            let skipped = now.title != before.title || (now.position() < 2 && before.position() > 4)
            guard !skipped else { return }
            if command == .previous {
                self.seek(to: 0)
            } else {
                self.runBrowser(browser, command: .next, mediaTabsOnly: true) { [weak self] clicked in
                    if !clicked { self?.showControlHint("No next track on this page") }
                }
            }
        }
    }

    private func showControlHint(_ text: String) {
        controlHint = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.controlHint == text { self?.controlHint = nil }
        }
    }

    func seek(to seconds: Double) {
        guard canSeek, var t = systemTrack else { return }
        AdapterStream.run(["seek", String(Int(seconds * 1_000_000))])
        t.elapsed = seconds
        t.elapsedAt = Date()
        systemTrack = t
        refreshShown()
    }

    /// Brings the shown player to the front; for a browser, the very tab that's playing.
    func openPlayer() {
        guard let bid = track?.bundleID else { return }
        open(bundleID: bid)
    }

    /// A browser goes to the tab playing (see `focusMediaTab`); any other player comes forward.
    func open(bundleID: String) {
        guard let browser = Self.browsers[bundleID] else { activateApp(bundleID); return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.unhide()
        let hint = track?.bundleID == bundleID ? track?.title : tabTitles[bundleID]
        let script = Self.focusTabScript(browser, titleHint: hint ?? "")
        scriptQueue.async { [weak self] in
            let found = !(Self.runScript(script)?.stringValue ?? "").isEmpty
            DispatchQueue.main.async { if !found { self?.activateApp(bundleID) } }
        }
    }

    /// Brings a player to the front with a window showing: unhides it, activates it, and sends
    /// the reopen a Dock click sends, so one whose window was closed opens it again.
    private func activateApp(_ bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.unhide()
            app.activate(options: [.activateAllWindows])
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { NSLog("win-tab: couldn't open player \(bundleID): \(error)") }
        }
    }

    // MARK: - Adapter payloads

    private var artworkKey: Int?

    /// An empty payload between two videos (a feed moving on) would flash "Nothing playing".
    private var pendingClear: DispatchWorkItem?
    private static let clearAfter: TimeInterval = 1.2

    private func apply(_ state: [String: Any]) {
        pendingClear?.cancel()
        pendingClear = nil
        guard let title = state["title"] as? String, !title.isEmpty, let bid = state["bundleIdentifier"] as? String else {
            guard systemTrack != nil else { return }
            let clear = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingClear = nil
                self.systemTrack = nil
                self.systemArtwork = nil
                self.systemTint = nil
                self.artworkKey = nil
                self.rebuildSources()
            }
            pendingClear = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearAfter, execute: clear)
            return
        }
        let elapsedAt = (state["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        systemTrack = Track(title: title, artist: state["artist"] as? String ?? "", playing: state["playing"] as? Bool ?? false,
                            player: Self.appName(bid), bundleID: bid, duration: state["duration"] as? Double ?? 0,
                            elapsed: state["elapsedTime"] as? Double ?? 0, elapsedAt: elapsedAt)
        let data = (state["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }
        let key = data?.hashValue
        if key != artworkKey {
            artworkKey = key
            systemArtwork = data.flatMap(NSImage.init(data:))
            systemTint = systemArtwork.flatMap(Self.vividAverage)
        }
        rebuildSources()
    }

    private static var appNames: [String: String] = [:]

    /// Looked up once per app: LaunchServices hits the disk.
    private static func appName(_ bundleID: String) -> String {
        if let name = appNames[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
        appNames[bundleID] = name
        return name
    }

    // MARK: - Sources

    private let sourceQueue = DispatchQueue(label: "win-tab.nowplaying.sources", qos: .utility)

    /// The CoreAudio scan walks processes with sysctl: off the main thread, so it can't land
    /// in the middle of an animation frame.
    private func pollSources() {
        scriptPollTick += 1
        // Titles for open Spotify/Music every other tick (3 s); without the adapter they're the only source.
        if scriptPollTick % 2 == 0 || adapter == nil {
            pollScripts()
            pollTabTitles()
        }
        sourceQueue.async { [weak self] in
            let ids = AudibleApps.bundleIDs()
            DispatchQueue.main.async {
                guard let self, ids != self.audibleIDs else { return }
                self.audibleIDs = ids
                self.rebuildSources()
            }
        }
    }

    private func rebuildSources() {
        var list: [Source] = []
        func add(_ id: String) {
            guard !list.contains(where: { $0.bundleID == id }), id != Bundle.main.bundleIdentifier else { return }
            list.append(Source(bundleID: id, name: Self.appName(id), audible: audibleIDs.contains(id), isSystem: id == systemTrack?.bundleID))
        }
        if let id = systemTrack?.bundleID { add(id) }
        audibleIDs.forEach(add)
        scriptTracks.keys.sorted().forEach(add)
        if list != sources { sources = list }
        refreshShown()
    }

    /// One for every artwork: a new CIContext per call built (and kept) its own caches each time.
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Average colour of the image, pushed to a usable brightness and saturation.
    private static func vividAverage(_ image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        c.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return Color(hue: h, saturation: min(1, max(s, 0.45) * 1.15), brightness: max(b, 0.8))
    }

    // MARK: - AppleScript: Spotify and Music

    /// Bundle ID → AppleScript application name.
    private static let scriptPlayers = ["com.spotify.client": "Spotify", "com.apple.Music": "Music"]

    private func pollScripts() {
        // Only players already running: scripting a closed one launches it.
        let running = Self.scriptPlayers.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.key).isEmpty }
        guard !running.isEmpty else {
            if !scriptTracks.isEmpty { scriptTracks = [:]; rebuildSources() }
            return
        }
        scriptQueue.async { [weak self] in
            var found: [String: Track] = [:]
            for (bid, name) in running {
                let script = """
                tell application "\(name)"
                    if player state is stopped then return ""
                    return (name of current track) & linefeed & (artist of current track) & linefeed & (player state as text) & linefeed & (player position as text) & linefeed & (duration of current track as text)
                end tell
                """
                guard let out = Self.runScript(script)?.stringValue, !out.isEmpty else { continue }
                let parts = out.components(separatedBy: "\n")
                guard parts.count >= 5 else { continue }
                let number = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                found[bid] = Track(title: parts[0], artist: parts[1], playing: parts[2] == "playing", player: name, bundleID: bid,
                                   duration: number(parts[4]) / (name == "Spotify" ? 1000 : 1), elapsed: number(parts[3]))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scriptTracks = found
                self.rebuildSources()
            }
        }
    }

    /// Runs on `scriptQueue` only: NSAppleScript isn't safe to use from several threads.
    nonisolated private static func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("win-tab: now playing script failed: \(error)") }
        return result
    }

    // MARK: - Browsers other than the system's player

    struct Browser { let name: String; let safari: Bool }
    private static let browsers: [String: Browser] = [
        "com.google.Chrome": Browser(name: "Google Chrome", safari: false),
        "com.brave.Browser": Browser(name: "Brave Browser", safari: false),
        "com.microsoft.edgemac": Browser(name: "Microsoft Edge", safari: false),
        "com.vivaldi.Vivaldi": Browser(name: "Vivaldi", safari: false),
        "company.thebrowser.Browser": Browser(name: "Arc", safari: false),
        "com.apple.Safari": Browser(name: "Safari", safari: true),
    ]

    /// Toggle pauses whatever plays in any tab, or resumes the first started one; next clicks
    /// YouTube's next button; previous restarts the media.
    private static func javaScript(_ command: Command) -> String {
        switch command {
        case .playpause:
            return "(()=>{const m=[...document.querySelectorAll('video,audio')];const p=m.filter(x=>!x.paused);if(p.length){p.forEach(x=>x.pause());return 'paused'}const q=m.find(x=>x.currentTime>0);if(q){q.play();return 'played'}return ''})()"
        case .next:
            // The page's own Next: YouTube, YouTube Music, SoundCloud, Spotify, then a labelled button.
            return "(()=>{const s=['.ytp-next-button','ytmusic-player-bar .next-button','.skipControl__next','[data-testid=control-button-skip-forward]','button[aria-label^=Next]','button[title^=Next]'];for(const q of s){const b=document.querySelector(q);if(b&&!b.disabled&&b.offsetParent!==null){b.click();return 'next'}}return ''})()"
        case .previous:
            return "(()=>{const m=[...document.querySelectorAll('video,audio')].find(x=>!x.paused||x.currentTime>0);if(m){m.currentTime=0;return 'restart'}return ''})()"
        }
    }

    /// Media sites whose tab is taken as "the one playing" (a browser doesn't say which tab makes sound).
    private static let mediaHosts = ["youtube.com/watch", "youtube.com/shorts", "music.youtube.com", "soundcloud.com", "open.spotify.com",
                                     "music.apple.com", "netflix.com", "twitch.tv", "nhaccuatui.com", "zingmp3.vn", "tiktok.com",
                                     "facebook.com/watch", "facebook.com/reel", "instagram.com/reel", "vimeo.com"]

    /// Makes the tab that's playing the browser's front tab: first the tab whose title holds the
    /// track's title (what the system reports for it), else a media-site tab whose media is
    /// actually playing (JavaScript, when the browser allows it), else the first media-site tab.
    /// Returns which rule found it, or "" when none did.
    static func focusTabScript(_ browser: Browser, titleHint: String) -> String {
        let hint = String(titleHint.prefix(80)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let hosts = mediaHosts.map { "\"\($0)\"" }.joined(separator: ", ")
        let js = "[...document.querySelectorAll('video,audio')].some(m=>!m.paused&&m.readyState>2)?'1':''"
        let titleOf = browser.safari ? "name of t" : "title of t"
        let runJS = browser.safari ? "do JavaScript \"\(js)\" in t" : "execute t javascript \"\(js)\""
        let pick = browser.safari ? "set current tab of w to t" : "set active tab index of w to ti"
        let pickFallback = browser.safari ? "set current tab of window fw to tab ft of window fw" : "set active tab index of window fw to ft"
        return """
        tell application "\(browser.name)"
            set hint to "\(hint)"
            set hosts to {\(hosts)}
            if hint is not "" then
                repeat with w in windows
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        if (\(titleOf)) contains hint then
                            \(pick)
                            set index of w to 1
                            activate
                            return "title"
                        end if
                    end repeat
                end repeat
            end if
            set fw to 0
            set ft to 0
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set ti to 0
                repeat with t in tabs of w
                    set ti to ti + 1
                    set u to URL of t
                    set isMedia to false
                    repeat with h in hosts
                        if u contains h then set isMedia to true
                    end repeat
                    if isMedia then
                        set isPlaying to ""
                        try
                            set isPlaying to (\(runJS))
                        end try
                        if isPlaying is "1" then
                            \(pick)
                            set index of w to 1
                            activate
                            return "playing"
                        end if
                        if fw is 0 then
                            set fw to wi
                            set ft to ti
                        end if
                    end if
                end repeat
            end repeat
            if fw > 0 then
                \(pickFallback)
                set index of window fw to 1
                activate
                return "host"
            end if
        end tell
        return ""
        """
    }

    /// Reads tab titles (no JavaScript needed) for audible browsers the system doesn't report on.
    private func pollTabTitles() {
        let wanted = audibleIDs.filter { $0 != systemTrack?.bundleID }.compactMap { id in Self.browsers[id].map { (id, $0) } }
        guard !wanted.isEmpty else {
            if !tabTitles.isEmpty { tabTitles = [:] }
            return
        }
        let hosts = Self.mediaHosts.map { "\"\($0)\"" }.joined(separator: ", ")
        scriptQueue.async { [weak self] in
            var titles: [String: String] = [:]
            for (id, browser) in wanted {
                let nameKey = browser.safari ? "name" : "title"
                let script = """
                tell application "\(browser.name)"
                    set hosts to {\(hosts)}
                    repeat with w in windows
                        repeat with t in tabs of w
                            set u to URL of t
                            repeat with h in hosts
                                if u contains h then return \(nameKey) of t
                            end repeat
                        end repeat
                    end repeat
                    return ""
                end tell
                """
                guard let title = Self.runScript(script)?.stringValue, !title.isEmpty else { continue }
                titles[id] = title.replacingOccurrences(of: " - YouTube Music", with: "").replacingOccurrences(of: " - YouTube", with: "")
            }
            DispatchQueue.main.async {
                guard let self, titles != self.tabTitles else { return }
                self.tabTitles = titles
                self.refreshShown()
            }
        }
    }

    /// Runs the command's JavaScript in the browser's tabs until one acts. `mediaTabsOnly` keeps
    /// Next to media sites, so a "Next" button in some form elsewhere is never clicked.
    private func runBrowser(_ browser: Browser, command: Command, mediaTabsOnly: Bool = false, done: ((Bool) -> Void)? = nil) {
        let script = Self.browserScript(browser, command: command, mediaTabsOnly: mediaTabsOnly)
        scriptQueue.async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            let failed = error != nil
            let acted = !(result?.stringValue ?? "").isEmpty
            if let error { NSLog("win-tab: browser command failed: \(error)") }
            let hint = error.flatMap { Self.hint(for: $0, browser: browser) }
            DispatchQueue.main.async {
                if let hint { self?.showBrowserHint(hint) }
                done?(acted || failed)
            }
        }
    }

    /// What to tell the user about a failed browser script; nil for errors they can't fix.
    nonisolated private static func hint(for error: NSDictionary, browser: Browser) -> BrowserHint? {
        // errAEEventNotPermitted: Privacy & Security › Automation has win-tab switched off.
        if error[NSAppleScript.errorNumber] as? Int == -1743 {
            return BrowserHint(text: "Allow win-tab to control \(browser.name) in Privacy & Security › Automation.", opensAutomation: true)
        }
        guard (error[NSAppleScript.errorMessage] as? String ?? "").localizedCaseInsensitiveContains("JavaScript") else { return nil }
        let menu = browser.safari ? "Develop" : "View › Developer"
        return BrowserHint(text: "Skip on this page needs \(browser.name) › \(menu) › Allow JavaScript from Apple Events.", opensAutomation: false)
    }

    private static let hintDuration: TimeInterval = 6

    private func showBrowserHint(_ hint: BrowserHint) {
        browserHint = hint
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintDuration) { [weak self] in
            if self?.browserHint == hint { self?.browserHint = nil }
        }
    }

    private static func browserScript(_ browser: Browser, command: Command, mediaTabsOnly: Bool) -> String {
        let js = Self.javaScript(command).replacingOccurrences(of: "\"", with: "\\\"")
        let run = browser.safari ? "do JavaScript \"\(js)\" in t" : "execute t javascript \"\(js)\""
        let media = Self.mediaHosts.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let body = mediaTabsOnly
            ? "set u to (URL of t)\n                    if \(media) then\n                        set r to (\(run))\n                        if r is not \"\" and r is not missing value then return r\n                    end if"
            : "set r to (\(run))\n                    if r is not \"\" and r is not missing value then return r"
        let script = """
        tell application "\(browser.name)"
            repeat with w in windows
                repeat with t in tabs of w
                    \(body)
                end repeat
            end repeat
        end tell
        return ""
        """
        return script
    }

    #if DEBUG
    /// Compiles (never runs) the browser scripts, so a quoting slip shows up here, not as a
    /// silent no-op when Next is pressed.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        for browser in [Browser(name: "Google Chrome", safari: false), Browser(name: "Safari", safari: true)] {
            for command in [Command.playpause, .next, .previous] {
                for tabs in [false, true] {
                    var error: NSDictionary?
                    if NSAppleScript(source: browserScript(browser, command: command, mediaTabsOnly: tabs))?.compileAndReturnError(&error) != true {
                        failures.append("now playing: \(browser.name) \(command) script: \(error?[NSAppleScript.errorMessage] ?? "?")")
                    }
                }
            }
            // A title with quotes and a backslash must still compile.
            var error: NSDictionary?
            if NSAppleScript(source: focusTabScript(browser, titleHint: "Say \"hi\" \\ now"))?.compileAndReturnError(&error) != true {
                failures.append("now playing: \(browser.name) focus tab script: \(error?[NSAppleScript.errorMessage] ?? "?")")
            }
        }
        return failures
    }
    #endif
}

/// Apps making sound right now, from CoreAudio's per-process output state (macOS 14.2+). Audio
/// often plays from a helper (Chrome's renderer), so each process is walked up to its app.
enum AudibleApps {
    nonisolated static func bundleIDs() -> [String] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [String] = []
        for id in ids where uint32(id, kAudioProcessPropertyIsRunningOutput) != 0 {
            guard let app = owningApp(pid_t(uint32(id, kAudioProcessPropertyPID))), let bid = app.bundleIdentifier, !out.contains(bid) else { continue }
            out.append(bid)
        }
        return out
    }

    nonisolated private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// The regular app a process belongs to, following parent processes (helpers, renderers).
    nonisolated private static func owningApp(_ pid: pid_t) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<6 where p > 1 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
            p = info.kp_eproc.e_ppid
        }
        return nil
    }
}

/// The adapter's `stream` command as a child process: JSON lines on stdout, each either the full
/// state or a diff to merge (keys set to null disappear).
@MainActor
private final class AdapterStream {
    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    private static var paths: (script: String, framework: String)? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter") else { return nil }
        let script = dir.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = dir.appendingPathComponent("MediaRemoteAdapter.framework").path
        let fm = FileManager.default
        return fm.fileExists(atPath: script) && fm.fileExists(atPath: framework) ? (script, framework) : nil
    }

    private let process = Process()
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var stopping = false

    init?(onPayload: @escaping ([String: Any]) -> Void, onExit: @escaping () -> Void) {
        guard let paths = Self.paths else { return nil }
        let pipe = Pipe()
        process.executableURL = Self.perl
        process.arguments = [paths.script, paths.framework, "stream", "--debounce=60"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                self.buffer.append(chunk)
                self.drain(onPayload)
            }
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                onExit()
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("win-tab: now playing adapter failed to start: \(error)")
            return nil
        }
    }

    func stop() {
        stopping = true
        if process.isRunning { process.terminate() }
    }

    private func drain(_ onPayload: ([String: Any]) -> Void) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { continue }
            if json["diff"] as? Bool == true {
                for (key, value) in payload {
                    if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
                }
            } else {
                state = payload
            }
            onPayload(state)
        }
    }

    /// Adapters left behind by a win-tab that crashed (now parented to launchd).
    static func killOrphans() {
        guard let script = paths?.script else { return }
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        ps.standardOutput = pipe
        do { try ps.run() } catch { return }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        for line in out.split(separator: "\n") where line.contains(script) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), fields[1] == "1" else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// One-off read of what's playing (`get`), off the main thread; nil if it couldn't run.
    static func read(_ done: @escaping @MainActor ([String: Any]?) -> Void) {
        guard let paths else { done(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = perl
            p.arguments = [paths.script, paths.framework, "get"]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var state: [String: Any]?
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                // "null" when nothing has ever played: an empty state, not a failure.
                state = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)).map { $0 as? [String: Any] ?? [:] }
            } catch {
                NSLog("win-tab: now playing read failed: \(error)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(state) } }
        }
    }

    /// One-off command (send, seek), fire and forget.
    static func run(_ arguments: [String]) {
        guard let paths else { return }
        let p = Process()
        p.executableURL = perl
        p.arguments = [paths.script, paths.framework] + arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { NSLog("win-tab: now playing command failed: \(error)") }
    }
}

/// The default output device's volume and mute, like the menu-bar volume control.
@MainActor
final class SystemVolume: ObservableObject {
    static let shared = SystemVolume()
    @Published private(set) var volume: Float = 0
    @Published private(set) var muted = false
    /// False for outputs without a software volume (some HDMI/USB devices).
    @Published private(set) var adjustable = true

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private var device: AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    func refresh() {
        let dev = device
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        adjustable = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr
        volume = vol
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = Self.address(kAudioDevicePropertyMute)
        if AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &size, &mute) == noErr { muted = mute != 0 }
    }

    func set(volume new: Float) {
        var v = Float32(min(max(new, 0), 1))
        var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr {
            volume = v
            if muted && v > 0 { set(muted: false) }
        }
    }

    func set(muted new: Bool) {
        var m = UInt32(new ? 1 : 0)
        var addr = Self.address(kAudioDevicePropertyMute)
        if AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr { muted = new }
    }
}
