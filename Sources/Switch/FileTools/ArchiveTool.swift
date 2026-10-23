import Foundation

struct RenamePattern: Equatable {
    /// Replaces each name when not empty; the files are then numbered from `start`.
    var newName = ""
    var start = 1
    var find = ""
    var replace = ""
    /// Without the dot; empty keeps each file's own.
    var newExtension = ""
}

struct RenameStep: Equatable {
    let from: URL
    let to: URL
}

enum ArchiveTool {
    /// One item zips to `<name>.zip`; several to `Archive.zip` beside the first, holding an
    /// `Archive` folder (the files are cloned there first: APFS clones take no space).
    static func zip(_ sources: [URL], cancel: CancelToken) throws -> URL {
        let dir = sources[0].deletingLastPathComponent()
        let base = sources.count == 1 ? sources[0].lastPathComponent : "Archive"
        let final = OutputNaming.unique(in: dir, base: base, ext: "zip")
        let partial = OutputNaming.partial(for: final)
        defer { try? FileManager.default.removeItem(at: partial) }
        var input = sources[0]
        var staging: URL?
        defer { if let staging { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) } }
        if sources.count > 1 {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("win-tab-zip-\(UUID().uuidString)").appendingPathComponent("Archive")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            staging = folder
            for url in sources {
                try cancel.check()
                let name = url.lastPathComponent
                let target = OutputNaming.unique(in: folder, base: (name as NSString).deletingPathExtension, ext: (name as NSString).pathExtension)
                try FileManager.default.copyItem(at: url, to: target)
            }
            input = folder
        }
        try ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, partial.path], cancel: cancel)
        return try OutputNaming.commit(partial, to: final)
    }

    /// Into a folder named after the archive, beside it.
    static func unzip(_ source: URL, cancel: CancelToken) throws -> URL {
        let folder = OutputNaming.unique(in: source.deletingLastPathComponent(), base: source.deletingPathExtension().lastPathComponent, ext: "")
        let partial = OutputNaming.partial(for: folder)
        defer { try? FileManager.default.removeItem(at: partial) }
        try ditto(["-x", "-k", source.path, partial.path], cancel: cancel)
        return try OutputNaming.commit(partial, to: folder)
    }

    private static func ditto(_ args: [String], cancel: CancelToken) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = args
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        cancel.onCancel { if process.isRunning { process.terminate() } }
        process.waitUntilExit()
        try cancel.check()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if message.localizedCaseInsensitiveContains("No space") { throw FileToolError.diskFull }
            throw FileToolError.failed(String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))
        }
    }

    // MARK: - Rename

    /// New names for `sources`, in order. Names used in the folder by files outside this batch,
    /// or earlier in the batch, get " 2", " 3"…; `/` and `:` become `-`.
    static func renamePreview(_ sources: [URL], pattern: RenamePattern) -> [RenameStep] {
        let batch = Set(sources.map { $0.path.lowercased() })
        let digits = String(pattern.start + max(sources.count - 1, 0)).count
        var taken = Set<String>()
        return sources.enumerated().map { i, url in
            let dir = url.deletingLastPathComponent()
            var name = url.deletingPathExtension().lastPathComponent
            if !pattern.newName.isEmpty { name = "\(pattern.newName) \(String(format: "%0\(digits)d", pattern.start + i))" }
            if !pattern.find.isEmpty { name = name.replacingOccurrences(of: pattern.find, with: pattern.replace) }
            name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = url.deletingPathExtension().lastPathComponent }
            let wanted = pattern.newExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            let ext = wanted.isEmpty ? url.pathExtension : wanted
            func file(_ stem: String) -> URL { dir.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)") }
            var stem = name
            var n = 2
            while taken.contains(file(stem).path.lowercased())
                    || (FileManager.default.fileExists(atPath: file(stem).path) && !batch.contains(file(stem).path.lowercased())) {
                stem = "\(name) \(n)"
                n += 1
            }
            taken.insert(file(stem).path.lowercased())
            return RenameStep(from: url, to: file(stem))
        }
    }

    /// Applies the steps that change something, through temporary names first so swaps and
    /// case-only changes work; on failure everything moved goes back. Returns what was applied.
    @discardableResult
    static func rename(_ steps: [RenameStep]) throws -> [RenameStep] {
        let fm = FileManager.default
        let moving = steps.filter { $0.from.path != $0.to.path }
        var parked: [(step: RenameStep, temp: URL)] = []
        var placed: [RenameStep] = []
        do {
            for step in moving {
                let temp = step.from.deletingLastPathComponent().appendingPathComponent(".win-tab-rename-\(UUID().uuidString)")
                try fm.moveItem(at: step.from, to: temp)
                parked.append((step, temp))
            }
            for (step, temp) in parked {
                try fm.moveItem(at: temp, to: step.to)
                placed.append(step)
            }
        } catch {
            for step in placed { try? fm.moveItem(at: step.to, to: step.from) }
            for (step, temp) in parked where fm.fileExists(atPath: temp.path) { try? fm.moveItem(at: temp, to: step.from) }
            throw FileToolError.from(error)
        }
        return moving
    }

    static func undo(_ applied: [RenameStep]) throws {
        try rename(applied.map { RenameStep(from: $0.to, to: $0.from) })
    }
}
