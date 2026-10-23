import AppKit
import ImageIO
import os
import Vision

/// Text from the screen (⌘⇧2 by default): drag over a region, the text in it goes on the
/// clipboard and the notch says how much. Ported from the standalone `ocr-region` tool; it uses
/// win-tab's Screen Recording permission, so `screencapture` needs no grant of its own.
@MainActor
enum OCRCapture {
    enum Outcome {
        case text(String)
        case noText
        case cancelled
        case failed(String)
    }

    private static var busy = false
    nonisolated static let log = Logger(subsystem: "com.mn.wintab", category: "ocr")

    static func run() {
        guard !busy else { return }
        busy = true
        // macOS can drop the recognition models after the app has sat a long while, and loading
        // them again takes seconds. Start that now, while the region is still being dragged.
        Task.detached(priority: .userInitiated) { await warm() }
        Task.detached(priority: .userInitiated) {
            let outcome = await capture()
            await MainActor.run {
                busy = false
                finish(outcome)
            }
        }
    }

    private static func finish(_ outcome: Outcome) {
        let accent = SwitchPreferences.shared.accent.color
        switch outcome {
        case .text(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let preview = text.split(separator: "\n").first.map { String($0.prefix(80)) } ?? ""
            show(NotchAlert(symbol: "text.viewfinder", title: "Copied \(text.count) characters", detail: preview,
                            color: accent, short: "Copied", badge: "\(text.count)"))
        case .noText:
            show(NotchAlert(symbol: "text.viewfinder", title: "No text found", detail: "Nothing readable in that region.",
                            color: .orange, short: "No text", badge: "0"))
        case .failed(let reason):
            show(NotchAlert(symbol: "exclamationmark.triangle.fill", title: "Text capture failed", detail: reason,
                            color: .red, short: "Failed", badge: "!"))
        case .cancelled:
            break
        }
    }

    /// The recognizer loads its models on first use, ~30 s on this Mac (the standalone tool paid
    /// that on every press, being a fresh process each time); later runs take ~150 ms. Pay it
    /// once, in the background, a while after launch, when the hotkey is bound.
    static func prewarm() {
        guard HotkeyConfig.shared[.ocr] != nil else { return }
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(20))
            // macOS drops the models after a while (a 2-day-old win-tab took ~37 s to read again).
            // A small read every few minutes keeps them loaded, or pays the reload here, in the
            // background, rather than on the next capture. ~0.1 s of CPU per read.
            while !Task.isCancelled {
                await warm()
                let saving = await MainActor.run { EnergySaver.isOn }
                try? await Task.sleep(for: .seconds(saving ? Self.keepWarmEvery * 2 : Self.keepWarmEvery))
            }
        }
    }

    nonisolated private static let keepWarmEvery: TimeInterval = 300

    /// Reads a small sample so the models are loaded. It needs text: a blank image never loads
    /// the recognition models.
    nonisolated static func warm() async {
        guard let context = CGContext(data: nil, width: 360, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 360, height: 48))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Xin chào Hà Nội 2026",
            attributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black]))
        context.textPosition = CGPoint(x: 10, y: 14)
        CTLineDraw(line, context)
        guard let sample = context.makeImage() else { return }
        let start = Date()
        _ = await recognize(sample)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if ms > 2000 {
            log.notice("warm-up read \(ms) ms: the models had been dropped and were loaded again")
        } else {
            log.info("warm-up read \(ms) ms")
        }
    }

    private static func show(_ alert: NotchAlert, duration: TimeInterval = 2.5) {
        guard UserDefaults.standard.object(forKey: OCROptions.showOnNotchKey) as? Bool ?? true else { return }
        _ = NotchController.current?.present(alert, duration: duration)
    }

    // MARK: - Capture and recognition (off the main thread)

    nonisolated private static func capture() async -> Outcome {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("win-tab-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: drag a region (Space switches to a window, Esc cancels); -x: no shutter sound.
        process.arguments = ["-i", "-x", url.path]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failed("Couldn't start the region picker.")
        }
        let picked = Date()
        process.waitUntilExit()
        log.info("region picked in \(Int(Date().timeIntervalSince(picked) * 1000)) ms (status \(process.terminationStatus))")
        let errText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            if ["not permitted", "permission", "could not create"].contains(where: errText.localizedCaseInsensitiveContains) {
                return .failed("Allow Screen Recording for win-tab in Privacy & Security.")
            }
            return .cancelled
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .failed("Couldn't read the capture.") }
        let start = Date()
        // A read that loads models runs for seconds: say so instead of looking stuck.
        let notice = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            show(NotchAlert(symbol: "text.viewfinder", title: "Reading text…", detail: "Loading the text models, a moment.",
                            color: SwitchPreferences.shared.accent.color, short: "Reading", badge: "…"), duration: 60)
        }
        let text = await recognize(image).trimmingCharacters(in: .whitespacesAndNewlines)
        notice.cancel()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if ms > 2000 {
            log.error("read took \(ms) ms for \(image.width)x\(image.height) px — models were cold")
        } else {
            log.info("read \(text.count) chars in \(ms) ms, \(image.width)x\(image.height) px")
        }
        return text.isEmpty ? .noText : .text(text)
    }

    /// Accurate first, fast if that finds nothing.
    ///
    /// Detect reads Vietnamese and English first (~0.3 s; those models stay loaded system-wide)
    /// and turns to language detection only when that leaves text unread — Chinese, Japanese,
    /// Korean, Thai come back as nothing at all. Detection's own models get dropped by macOS
    /// after a while and take ~35 s to load again, which made every capture slow.
    nonisolated static func recognize(_ image: CGImage, options: OCROptions = .current) async -> String {
        var found: [OCRLayout.Item]
        if options.languages == .automatic {
            var latin = options
            latin.languages = .vietnameseEnglish
            async let regions = textRegions(image)
            found = await observe(image, options: latin, level: .accurate)
            let unread = await regions.filter { region in
                !found.contains { $0.box.insetBy(dx: -4, dy: -4).contains(CGPoint(x: region.midX, y: region.midY)) }
            }.count
            if found.isEmpty || (unread >= 3 && unread > found.count) {
                log.info("\(unread) text regions unread in Vietnamese/English; detecting the language")
                found = await observe(image, options: options, level: .accurate)
            }
        } else {
            found = await observe(image, options: options, level: .accurate)
        }
        if found.isEmpty { found = await observe(image, options: options, level: .fast) }
        return OCRLayout.text(found, layout: options.layout)
    }

    /// Where text is, in pixels (top-left origin), without reading it: language-free and quick
    /// (a few ms, ~40 ms for a full Retina screen).
    nonisolated private static func textRegions(_ image: CGImage) async -> [CGRect] {
        let size = CGSize(width: image.width, height: image.height)
        func pixels(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
        }
        if #available(macOS 15.0, *) {
            return ((try? await DetectTextRectanglesRequest().perform(on: image)) ?? []).map { pixels($0.boundingBox.cgRect) }
        }
        let request = VNDetectTextRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map { pixels($0.boundingBox) }
    }

    /// Recognised lines with their boxes in pixels, top-left origin.
    nonisolated private static func observe(_ image: CGImage, options: OCROptions, level: OCROptions.Level) async -> [OCRLayout.Item] {
        let size = CGSize(width: image.width, height: image.height)
        func pixels(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
        }
        if #available(macOS 15.0, *) {
            var request = RecognizeTextRequest()
            request.recognitionLevel = level == .accurate ? .accurate : .fast
            request.usesLanguageCorrection = options.correction
            switch options.languages {
            case .automatic: request.automaticallyDetectsLanguage = true
            case .vietnameseEnglish: request.recognitionLanguages = [Locale.Language(identifier: "vi-VT"), Locale.Language(identifier: "en-US")]
            case .english: request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
            }
            var observations = (try? await request.perform(on: image)) ?? []
            if observations.isEmpty, options.languages != .automatic {
                // A language the recognizer can't load: retry with its defaults.
                request.recognitionLanguages = []
                observations = (try? await request.perform(on: image)) ?? []
            }
            return observations.compactMap { o in o.topCandidates(1).first.map { OCRLayout.Item(box: pixels(o.boundingBox.cgRect), text: $0.string) } }
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = options.correction
        switch options.languages {
        case .automatic: request.automaticallyDetectsLanguage = true
        case .vietnameseEnglish: request.recognitionLanguages = ["vi-VT", "en-US"]
        case .english: request.recognitionLanguages = ["en-US"]
        }
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { o in o.topCandidates(1).first.map { OCRLayout.Item(box: pixels(o.boundingBox), text: $0.string) } }
    }
}

/// Settings → Text from screen. Read off the main thread, so straight from UserDefaults.
struct OCROptions: Sendable {
    enum Languages: String, CaseIterable, Identifiable, Sendable {
        case automatic, vietnameseEnglish, english
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Detect (any language)"
            case .vietnameseEnglish: return "Vietnamese + English"
            case .english: return "English"
            }
        }
    }

    enum Layout: String, CaseIterable, Identifiable, Sendable {
        case lines, paragraphs
        var id: String { rawValue }
        var label: String { self == .lines ? "Keep lines" : "Join paragraphs" }
    }

    enum Level: Sendable { case accurate, fast }

    static let languagesKey = "switch.ocr.languages"
    static let correctionKey = "switch.ocr.correction"
    static let layoutKey = "switch.ocr.layout"
    static let showOnNotchKey = "switch.ocr.showOnNotch"

    var languages: Languages
    var correction: Bool
    var layout: Layout

    static var current: OCROptions {
        let d = UserDefaults.standard
        return OCROptions(languages: Languages(rawValue: d.string(forKey: languagesKey) ?? "") ?? .automatic,
                          correction: d.object(forKey: correctionKey) as? Bool ?? true,
                          layout: Layout(rawValue: d.string(forKey: layoutKey) ?? "") ?? .lines)
    }
}

/// Reading order for recognised lines: columns left to right, rows top to bottom; boxes on one
/// row are a table row (tab-separated) when far apart, words of one line when close.
enum OCRLayout {
    struct Item { let box: CGRect; let text: String }

    static func text(_ items: [Item], layout: OCROptions.Layout) -> String {
        guard !items.isEmpty else { return "" }
        let lineHeight = items.map(\.box.height).sorted()[items.count / 2]
        return columns(items, lineHeight: lineHeight)
            .map { column in render(rows(column), lineHeight: lineHeight, layout: layout) }
            .joined(separator: "\n\n")
    }

    /// Splits at a clear vertical gutter when the two sides don't line up row by row (text
    /// columns); aligned sides are a table and stay together.
    static func columns(_ items: [Item], lineHeight: CGFloat) -> [[Item]] {
        let sorted = items.sorted { $0.box.minX < $1.box.minX }
        var reach = sorted[0].box.maxX
        for (i, item) in sorted.enumerated().dropFirst() {
            if item.box.minX - reach > lineHeight * 1.5 {
                let left = Array(sorted[..<i]), right = Array(sorted[i...])
                if left.count >= 2, right.count >= 2, !alignedRows(left, right, lineHeight: lineHeight) {
                    return columns(left, lineHeight: lineHeight) + columns(right, lineHeight: lineHeight)
                }
            }
            reach = max(reach, item.box.maxX)
        }
        return [items]
    }

    /// Most boxes on the narrower side share a row with a box on the other side.
    private static func alignedRows(_ a: [Item], _ b: [Item], lineHeight: CGFloat) -> Bool {
        let (few, many) = a.count <= b.count ? (a, b) : (b, a)
        // Table cells share a baseline almost exactly; side-by-side text columns drift.
        let matched = few.filter { x in many.contains { abs($0.box.midY - x.box.midY) < lineHeight * 0.15 } }.count
        return Double(matched) >= Double(few.count) * 0.8
    }

    /// Rows by vertical overlap (half the shorter box), top to bottom, each left to right.
    static func rows(_ items: [Item]) -> [[Item]] {
        var rows: [[Item]] = []
        for item in items.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let i = rows.lastIndex(where: { row in
                row.contains { overlap($0.box, item.box) >= min($0.box.height, item.box.height) * 0.5 }
            }) {
                rows[i].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat { max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY)) }

    private static func render(_ rows: [[Item]], lineHeight: CGFloat, layout: OCROptions.Layout) -> String {
        let lines = rows.map { row -> String in
            var line = row[0].text
            for (prev, item) in zip(row, row.dropFirst()) {
                line += item.box.minX - prev.box.maxX > lineHeight * 1.5 ? "\t" : " "
                line += item.text
            }
            return line
        }
        guard layout == .paragraphs else { return lines.joined(separator: "\n") }
        var out = lines[0]
        for i in 1..<lines.count {
            let gap = rows[i][0].box.minY - rows[i - 1][0].box.maxY
            if gap > lineHeight * 0.9 || lines[i].contains("\t") || lines[i - 1].contains("\t") {
                out += "\n" + lines[i]
            } else if out.hasSuffix("-"), out.dropLast().last?.isLetter == true {
                out = String(out.dropLast()) + lines[i]
            } else {
                out += " " + lines[i]
            }
        }
        return out
    }
}
