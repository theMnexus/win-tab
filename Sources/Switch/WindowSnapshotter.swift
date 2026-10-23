import AppKit
import ScreenCaptureKit

actor WindowSnapshotter {
    static let shared = WindowSnapshotter()

    /// Longest edge kept in the cache: the largest place a thumbnail is drawn (a ⌘-Tab tile or
    /// a Dock hover card), at 2x. A fixed 960 px kept ~2.3 MB per window where ~1 MB shows.
    private nonisolated static var maxPixelEdge: CGFloat {
        let d = UserDefaults.standard
        let thumb = CGFloat((d.object(forKey: SwitchPreferences.thumbnailHeightKey) as? Double) ?? SwitchPreferences.defaultThumbnailHeight)
        let cols = CGFloat(max(1, (d.object(forKey: SwitchPreferences.gridColumnsKey) as? Int) ?? SwitchPreferences.defaultGridColumns))
        // Same column width as SwitcherPanelSize.gridSize.
        let column = (880 * thumb / CGFloat(SwitchPreferences.defaultThumbnailHeight) - 44 - (cols - 1) * 14) / cols
        let dockCard: CGFloat = 260
        return min(960, ceil(max(column, thumb, dockCard) * 2))
    }

    private var cache: [CGWindowID: NSImage] = [:]
    private var inFlight: Set<CGWindowID> = []
    private var shareableContent: SCShareableContent?
    private var shareableContentAt: Date = .distantPast
    private var shareableContentTask: Task<SCShareableContent?, Never>?

    /// One SCShareableContent enumeration per second, shared across every
    /// concurrent snapshot call. Per-window fetches were N full enumerations
    /// per refresh tick.
    private func currentShareableContent() async -> SCShareableContent? {
        if let c = shareableContent, Date().timeIntervalSince(shareableContentAt) < 1.0 { return c }
        if let task = shareableContentTask { return await task.value }
        let task = Task<SCShareableContent?, Never> {
            try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        shareableContentTask = task
        let c = await task.value
        shareableContentTask = nil
        if let c {
            shareableContent = c
            shareableContentAt = Date()
        }
        return c
    }

    func snapshot(for id: CGWindowID, force: Bool = false) async -> NSImage? {
        if !force, let img = cache[id] { return img }
        if inFlight.contains(id) { return nil }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        // Non-shareable = DRM; the capture attempts are what players detect and block on.
        if !isShareable(id) { return nil }

        if let img = captureViaCG(id: id) {
            cache[id] = img
            return img
        }

        if let img = await captureViaSCK(id: id) {
            cache[id] = img
            return img
        }
        return nil
    }

    private func captureViaSCK(id: CGWindowID) async -> NSImage? {
        do {
            guard let content = await currentShareableContent(),
                  let scWindow = content.windows.first(where: { $0.windowID == id }) else { return nil }
            var filter: SCContentFilter?
            var reason: NSString?
            _ = switch_try({ filter = SCContentFilter(desktopIndependentWindow: scWindow) }, &reason)
            guard let filter else { return nil }
            let cfg = SCStreamConfiguration()
            let scale = min(1, Self.maxPixelEdge / max(scWindow.frame.width, scWindow.frame.height, 1))
            cfg.width = max(1, Int(scWindow.frame.width * scale))
            cfg.height = max(1, Int(scWindow.frame.height * scale))
            cfg.showsCursor = false
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } catch {
            return nil
        }
    }

    private nonisolated func isShareable(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let sharing = list.first?["kCGWindowSharingType"] as? Int else {
            return true
        }
        return sharing != 0
    }

    private nonisolated func captureViaCG(id: CGWindowID) -> NSImage? {
        // CGWindowListCreateImage is deprecated in 14+ but the only path for off-Space windows.
        let opts: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id, opts) else {
            return nil
        }
        guard cg.width > 0, cg.height > 0 else { return nil }
        let small = Self.downscaled(cg)
        return NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
    }

    private nonisolated static func downscaled(_ cg: CGImage) -> CGImage {
        let longest = CGFloat(max(cg.width, cg.height))
        let edge = maxPixelEdge
        guard longest > edge else { return cg }
        let scale = edge / longest
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard let space = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return cg }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    /// Drop cached entries for windows no longer in `keep`. Used by the pre-warm path
    /// so live thumbs survive between panel opens but dead window IDs don't accumulate.
    func purge(keeping keep: Set<CGWindowID>) {
        cache = cache.filter { keep.contains($0.key) }
    }
}
