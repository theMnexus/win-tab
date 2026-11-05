import AppKit
import CoreML
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

    /// On the CPU, revision 2's first read is about 0.1 s. Now and then macOS rebuilds its text
    /// assets system-wide and that first read takes about 20 s. Pay it in the background, a
    /// while after launch, when the hotkey is bound.
    static func prewarm() {
        guard HotkeyConfig.shared[.ocr] != nil else { return }
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(20))
            // A small read every few minutes keeps revision 2 loaded, or pays a reload here
            // instead of on the next capture. About 40 ms of CPU per read.
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

    /// Accurate first. Fast only when accurate finds nothing.
    ///
    /// macOS 27's default text model (revision 3, and `RecognizeTextRequest`) stalls 15 to 40 s,
    /// then fails with e5rt error 13 for the rest of the process. Revision 2 on the CPU stays near
    /// 40 ms and keeps Vietnamese diacritics (see `runOnCPU`). Chinese is a second revision-2 pass,
    /// and only when the Latin pass is empty or below 0.5 confidence.
    nonisolated static func recognize(_ image: CGImage, options: OCROptions = .current) async -> String {
        let latin = options.languages == .automatic ? options.withLanguages(.vietnameseEnglish) : options
        var found = await observe(image, options: latin, level: .accurate)
        if options.languages == .automatic, found.isEmpty || found.allSatisfy({ $0.confidence < 0.5 }) {
            let chinese = await observe(image, options: options.withScript(.chinese), level: .accurate)
            if chinese.contains(where: { $0.confidence >= 0.5 }) { found = chinese }
        }
        if found.isEmpty { found = await observe(image, options: latin, level: .fast) }
        return OCRLayout.text(found, layout: options.layout)
    }

    /// Recognised lines with their boxes in pixels, top-left origin.
    nonisolated private static func observe(_ image: CGImage, options: OCROptions, level: OCROptions.Level) async -> [OCRLayout.Item] {
        let size = CGSize(width: image.width, height: image.height)
        func pixels(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height,
                   width: r.width * size.width, height: r.height * size.height)
        }
        func makeRequest(onCPU: Bool) -> VNRecognizeTextRequest {
            let request = VNRecognizeTextRequest()
            if VNRecognizeTextRequest.supportedRevisions.contains(2) {
                request.revision = 2
            }
            request.recognitionLevel = level == .accurate ? .accurate : .fast
            request.usesLanguageCorrection = options.correction
            // Revision 2 has no "vi-VT" (it lists en, fr, it, de, es, pt, zh). Its Latin model
            // still reads Vietnamese diacritics, so Vietnamese and English share "en-US".
            request.recognitionLanguages = options.script == .chinese ? ["zh-Hans", "zh-Hant"] : ["en-US"]
            if onCPU { runOnCPU(request) }
            return request
        }
        var request = makeRequest(onCPU: true)
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            // CPU is the normal path; the default devices are only a second try.
            log.error("CPU read failed, retrying on default devices: \(error.localizedDescription, privacy: .public)")
            request = makeRequest(onCPU: false)
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                log.error("read failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map {
                OCRLayout.Item(box: pixels(observation.boundingBox), text: $0.string, confidence: $0.confidence)
            }
        }
    }

    /// Runs every stage of the request on the CPU.
    ///
    /// On the Neural Engine, macOS 27.2 sometimes reloads the text model in a long-running process
    /// and then fails every read with "E5RT Error ... (Code: 13)" until the app quits (seen after
    /// 41 h: 136 failed reads in a row). On the CPU revision 2 gives the same text in 40-110 ms and
    /// needs no Neural Engine compile.
    nonisolated private static func runOnCPU(_ request: VNRecognizeTextRequest) {
        guard let stages = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
    }
}

/// Settings → Text from screen. Read off the main thread, so straight from UserDefaults.
struct OCROptions: Sendable {
    enum Languages: String, CaseIterable, Identifiable, Sendable {
        case automatic, vietnameseEnglish, english
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Auto (Latin + Chinese)"
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

    /// Which revision-2 model to run. Chinese is not a Settings choice. Automatic tries it
    /// only after Vietnamese and English come back empty or unsure.
    enum Script: Sendable { case settings, chinese }

    var languages: Languages
    var correction: Bool
    var layout: Layout
    var script: Script = .settings

    func withLanguages(_ languages: Languages) -> OCROptions {
        OCROptions(languages: languages, correction: correction, layout: layout, script: .settings)
    }

    func withScript(_ script: Script) -> OCROptions {
        OCROptions(languages: languages, correction: correction, layout: layout, script: script)
    }

    static var current: OCROptions {
        let d = UserDefaults.standard
        return OCROptions(languages: Languages(rawValue: d.string(forKey: languagesKey) ?? "") ?? .automatic,
                          correction: d.object(forKey: correctionKey) as? Bool ?? true,
                          layout: Layout(rawValue: d.string(forKey: layoutKey) ?? "") ?? .lines,
                          script: .settings)
    }
}

/// Reading order for recognised lines: columns left to right, rows top to bottom; boxes on one
/// row are a table row (tab-separated) when far apart, words of one line when close.
enum OCRLayout {
    struct Item { let box: CGRect; let text: String; let confidence: Float }

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
