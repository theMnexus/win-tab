import Foundation

/// Where results go: next to the original, never over an existing file.
enum OutputNaming {
    /// `photo.png` + ("compressed", "png") → `photo (compressed).png`; (nil, "jpg") → `photo.jpg`.
    /// A convert that keeps the extension gets " (converted)"; a taken name gets " 2", " 3"…
    static func next(to source: URL, suffix: String?, ext: String) -> URL {
        var base = source.deletingPathExtension().lastPathComponent
        if let suffix {
            base += " (\(suffix))"
        } else if ext.lowercased() == source.pathExtension.lowercased() {
            base += " (converted)"
        }
        return unique(in: source.deletingLastPathComponent(), base: base, ext: ext)
    }

    /// `base.ext` in `dir`, or `base 2.ext`, `base 3.ext`… An empty `ext` names a folder.
    static func unique(in dir: URL, base: String, ext: String) -> URL {
        func candidate(_ n: Int) -> URL {
            let name = n == 1 ? base : "\(base) \(n)"
            return dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        }
        var n = 1
        while FileManager.default.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }

    /// Hidden working name beside the final one: `.photo.partial.jpg` (folders: `.name.partial`).
    static func partial(for final: URL) -> URL {
        let ext = final.pathExtension
        let stem = final.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? ".\(final.lastPathComponent).partial" : ".\(stem).partial.\(ext)"
        return final.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// ImageIO writes through `.<name>-XXXXXX` beside its destination and can leave it behind
    /// when a write fails.
    static func removeImageIOTemporaries(of url: URL) {
        let dir = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent)-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Moves the finished partial into place; a name taken meanwhile gets the next number.
    @discardableResult
    static func commit(_ partial: URL, to final: URL) throws -> URL {
        var target = final
        if FileManager.default.fileExists(atPath: final.path) {
            target = unique(in: final.deletingLastPathComponent(), base: final.deletingPathExtension().lastPathComponent, ext: final.pathExtension)
        }
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }
}
