// Self-check for Sources/Switch/FileTools (no UI). Run:
//   swiftc -parse-as-library -O tools/filetools-check.swift Sources/Switch/FileTools/{FileOperation,OutputNaming,ImageTool,MediaTool,PDFTool,ArchiveTool,FileTools}.swift -o /tmp/filetools-check && /tmp/filetools-check
// Builds its own sample files in a temporary folder; exits non-zero on the first failed check.
import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Holds the last progress value a tool reported.
final class ProgressBox: @unchecked Sendable { var value = 0.0 }

@main
struct FileToolsCheck {
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filetools-check-\(UUID().uuidString)")
    static var passed = 0

    static func check(_ ok: Bool, _ what: String, line: UInt = #line) {
        guard ok else { print("FAIL \(what) (line \(line))"); exit(1) }
        passed += 1
    }

    static func digest(_ url: URL) -> String {
        SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    static func size(_ url: URL) -> Int64 { FileSize.of([url]) }

    static func run(_ op: FileOperation, _ inputs: [URL], cancel: CancelToken = CancelToken(), progress: ProgressBox = ProgressBox()) async throws -> URL {
        try await FileTools.perform(op, inputs: inputs, options: FileToolOptions(), cancel: cancel) { progress.value = $0 }[0]
    }

    static func main() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await namingChecks()
        try await imageChecks()
        try await mediaChecks()
        try await pdfChecks()
        try await archiveChecks()
        print("PASS \(passed) checks")
    }

    // MARK: Naming and kinds (Task 2)

    static func namingChecks() async throws {
        let photo = dir.appendingPathComponent("photo.png")
        try Data([0]).write(to: photo)
        check(OutputNaming.next(to: photo, suffix: "compressed", ext: "png").lastPathComponent == "photo (compressed).png", "suffix name")
        check(OutputNaming.next(to: photo, suffix: nil, ext: "jpg").lastPathComponent == "photo.jpg", "converted name")
        check(OutputNaming.next(to: photo, suffix: nil, ext: "png").lastPathComponent == "photo (converted).png", "same-extension convert gets a suffix")
        try Data([0]).write(to: dir.appendingPathComponent("photo.jpg"))
        check(OutputNaming.next(to: photo, suffix: nil, ext: "jpg").lastPathComponent == "photo 2.jpg", "taken name is numbered")
        check(OutputNaming.partial(for: dir.appendingPathComponent("photo 2.jpg")).lastPathComponent == ".photo 2.partial.jpg", "partial keeps the extension")
        check(FileKind.of(photo) == .image && FileKind.of(dir.appendingPathComponent("a.mov")) == .video
              && FileKind.of(dir.appendingPathComponent("a.pdf")) == .pdf && FileKind.of(dir.appendingPathComponent("a.zip")) == .archive
              && FileKind.of(dir.appendingPathComponent("a.m4a")) == .audio && FileKind.of(dir.appendingPathComponent("a.txt")) == .other, "kinds")
        // Review focus 3: a shelved file that vanished fails on its own.
        do {
            _ = try await run(.compressImage, [dir.appendingPathComponent("gone.png")])
            check(false, "missing file must fail")
        } catch let error as FileToolError {
            check(error == .unreadable("gone.png"), "missing file reports unreadable")
        }
        try FileManager.default.removeItem(at: photo)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("photo.jpg"))
    }

    /// A 4000×3000 image of many coloured blocks (so compression has work to do); with alpha the
    /// bottom-left 100×100 stays transparent.
    static func makeImage(_ name: String, type: UTType, alpha: Bool, gps: Bool, quality: Double = 1) throws -> URL {
        let w = 4000, h = 3000
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        for i in 0..<400 {
            let c = CGFloat(i % 17) / 17
            ctx.setFillColor(CGColor(red: c, green: 1 - c, blue: CGFloat(i % 5) / 5, alpha: 1))
            ctx.fill(CGRect(x: (i * 97) % w, y: (i * 53) % h, width: 300, height: 200))
        }
        if alpha { ctx.clear(CGRect(x: 0, y: 0, width: 100, height: 100)) }
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 10.77, kCGImagePropertyGPSLatitudeRef: "N",
                                                   kCGImagePropertyGPSLongitude: 106.70, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }

    static func imageInfo(_ url: URL) -> (type: String, width: Int, height: Int, props: [CFString: Any]) {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        return (CGImageSourceGetType(src)! as String, props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int, props)
    }

    /// RGB of one pixel, (x, y) from the top-left.
    static func pixel(_ url: URL, x: Int, y: Int) -> [UInt8] {
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        let spot = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(spot, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(px.prefix(3))
    }

    static func imageChecks() async throws {
        let png = try makeImage("alpha.png", type: .png, alpha: true, gps: false)
        let jpg = try makeImage("gps.jpg", type: .jpeg, alpha: false, gps: true)
        let pngHash = digest(png), jpgHash = digest(jpg)

        let toJPG = try await run(.convertImage(.jpeg), [png])
        check(imageInfo(toJPG).type == UTType.jpeg.identifier && toJPG.lastPathComponent == "alpha.jpg", "PNG → JPG")
        // Review focus 1: transparency becomes white, not black.
        check(pixel(toJPG, x: 10, y: 2990).allSatisfy { $0 > 240 }, "transparent PNG → JPG is white underneath")

        for format in [ImageFormat.heic, .avif, .tiff] {
            let out = try await run(.convertImage(format), [jpg])
            check(UTType(imageInfo(out).type)?.conforms(to: format.type) == true, "JPG → \(format.label)")
        }
        let asPDF = try await run(.convertImage(.pdf), [jpg])
        check(PDFDocument(url: asPDF)?.pageCount == 1, "JPG → PDF")

        let compressed = try await run(.compressImage, [jpg])
        check(compressed.lastPathComponent == "gps (compressed).jpg" && size(compressed) < size(jpg), "compress JPG is smaller")
        let pngCompressed = try await run(.compressImage, [png])
        check(pngCompressed.pathExtension == "heic", "PNG compresses to HEIC")

        let resized = try await run(.resizeImage(maxEdge: 1920), [jpg])
        let r = imageInfo(resized)
        check(max(r.width, r.height) == 1920 && resized.lastPathComponent == "gps (1920px).jpg", "resize long edge 1920")
        let again = try await run(.resizeImage(maxEdge: 3840), [resized])
        check(max(imageInfo(again).width, imageInfo(again).height) == 1920, "never upscales")

        check(imageInfo(jpg).props[kCGImagePropertyGPSDictionary] != nil, "fixture has GPS")
        let stripped = try await run(.stripMetadata, [jpg])
        let s = imageInfo(stripped)
        check(s.props[kCGImagePropertyGPSDictionary] == nil && s.width == 4000, "strip removes GPS, keeps pixels")

        // A JPEG saved at low quality and re-encoded at 0.8 grows: keep the original.
        let tiny = try makeImage("tiny.jpg", type: .jpeg, alpha: false, gps: false, quality: 0.2)
        let grown = try await run(.compressImage, [tiny])
        do {
            _ = try FileTools.finish(.compressImage, inputs: [tiny], outputs: [grown], replaceOriginal: false)
            check(false, "bigger result must be refused")
        } catch let e as FileToolError {
            check(e == .alreadyOptimized && !FileManager.default.fileExists(atPath: grown.path), "bigger result removed")
        }
        check(digest(png) == pngHash && digest(jpg) == jpgHash, "originals untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".partial") }
        check(leftovers.isEmpty, "no partial files left: \(leftovers)")
    }
    /// A 5 s 1920×1080 H.264 clip of noise at 40 Mbps (no audio track): long enough to cancel mid-way.
    static func makeVideo() async throws -> URL {
        let url = dir.appendingPathComponent("clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<150 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt32.self)
            let count = CVPixelBufferGetBytesPerRow(buffer!) / 4 * 1080
            var seed = UInt32(truncatingIfNeeded: frame &* 2_654_435_761)
            for i in 0..<count { seed = seed &* 1_103_515_245 &+ 12_345; base[i] = seed }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// 2 s of a 440 Hz tone.
    static func makeTone() throws -> URL {
        let url = dir.appendingPathComponent("tone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200)!
        buffer.frameLength = 88_200
        for i in 0..<88_200 { buffer.floatChannelData![0][i] = sinf(Float(i) * 2 * .pi * 440 / 44_100) * 0.3 }
        try file.write(from: buffer)
        return url
    }

    static func mediaChecks() async throws {
        let video = try await makeVideo()
        let tone = try makeTone()
        let hash = digest(video)
        let progress = ProgressBox()
        let small = try await run(.compressVideo(.hevc1080), [video], progress: progress)
        check(small.lastPathComponent == "clip (compressed).mp4" && size(small) < size(video), "HEVC compress is smaller")
        check(progress.value == 1, "progress reaches 1")
        let mp4 = try await run(.convertVideo(.mp4), [video])
        check(mp4.lastPathComponent == "clip.mp4", "MOV → MP4")
        let m4a = try await run(.toAudio, [tone])
        check(m4a.pathExtension == "m4a" && size(m4a) > 0, "audio → M4A")
        // Review focus 4: no sound, no empty file.
        do {
            _ = try await run(.toAudio, [video])
            check(false, "silent video must fail")
        } catch let e as FileToolError {
            check(e == .noAudio && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("clip.m4a").path), "silent video → noAudio")
        }
        // Cancel mid-export leaves nothing behind.
        let token = CancelToken()
        _ = Task { try await Task.sleep(nanoseconds: 100_000_000); token.cancel() }
        do {
            _ = try await run(.compressVideo(.h264_720), [video], cancel: token)
            check(false, "cancel must stop the export")
        } catch let e as FileToolError {
            check(e == .cancelled, "cancel reports cancelled")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".partial") || $0.hasPrefix("clip (compressed) 2") }
        check(leftovers.isEmpty, "cancel leaves no file")
        check(digest(video) == hash, "video untouched")
    }
    /// Three A4 pages, each a 2000×1500 photo-like (noisy) image, so screen optimization has
    /// something to shrink (flat colour blocks are already tiny in a PDF).
    static func makePDF(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        let w = 2000, h = 1500
        let pixels = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let base = pixels.data!.assumingMemoryBound(to: UInt32.self)
        var seed: UInt32 = 7
        for i in 0..<(w * h) { seed = seed &* 1_103_515_245 &+ 12_345; base[i] = seed }
        let image = pixels.makeImage()!
        for _ in 0..<3 {
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    static func pdfChecks() async throws {
        let a = try makePDF("a.pdf"), b = try makePDF("b.pdf")
        let small = try await run(.compressPDF, [a])
        check(small.lastPathComponent == "a (compressed).pdf" && size(small) < size(a), "PDF compress is smaller: \(size(a)) → \(size(small)) bytes")
        let merged = try await run(.mergePDFs, [a, b])
        check(merged.lastPathComponent == "Merged.pdf" && PDFDocument(url: merged)?.pageCount == 6, "merge 3+3 pages")
        let pages = try await run(.pdfToImages, [a])
        let files = try FileManager.default.contentsOfDirectory(atPath: pages.path).sorted()
        check(pages.lastPathComponent == "a pages" && files == ["page 1.png", "page 2.png", "page 3.png"], "PDF → 3 PNGs")
        check(imageInfo(pages.appendingPathComponent("page 1.png")).width == 1190, "144 dpi page width")
        let photo = try makeImage("shot.jpg", type: .jpeg, alpha: false, gps: false)
        let fromImages = try await run(.imagesToPDF, [photo, photo])
        check(fromImages.lastPathComponent == "Images.pdf" && PDFDocument(url: fromImages)?.pageCount == 2, "images → PDF")
    }

    static func archiveChecks() async throws {
        let folder = dir.appendingPathComponent("zipme")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let one = folder.appendingPathComponent("one.txt"), two = folder.appendingPathComponent("two.txt")
        try "hello".write(to: one, atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 50_000).write(to: two, atomically: true, encoding: .utf8)
        let zip = try await run(.zip, [one, two])
        check(zip.lastPathComponent == "Archive.zip" && size(zip) > 0, "zip two files")
        let out = try await run(.unzip, [zip])
        check(FileManager.default.fileExists(atPath: out.appendingPathComponent("Archive/two.txt").path), "unzip restores files")
        check(digest(out.appendingPathComponent("Archive/two.txt")) == digest(two), "unzipped content matches")

        // Rename: numbering, preview, undo.
        let shots = (1...3).map { folder.appendingPathComponent("IMG_\($0).jpg") }
        try shots.forEach { try Data([1]).write(to: $0) }
        let plan = ArchiveTool.renamePreview(shots, pattern: RenamePattern(newName: "Trip", start: 1))
        check(plan.map(\.to.lastPathComponent) == ["Trip 1.jpg", "Trip 2.jpg", "Trip 3.jpg"], "rename preview numbers")
        let applied = try ArchiveTool.rename(plan)
        check(applied.allSatisfy { FileManager.default.fileExists(atPath: $0.to.path) }, "renamed")
        try ArchiveTool.undo(applied)
        check(shots.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "undo restores names")
        // Review focus 2: case-only change, and a swap in one batch.
        let upper = folder.appendingPathComponent("photo.JPG")
        try Data([2]).write(to: upper)
        let caseOnly = ArchiveTool.renamePreview([upper], pattern: RenamePattern(newExtension: "jpg"))
        check(caseOnly[0].to.lastPathComponent == "photo.jpg", "case-only rename keeps the name")
        try ArchiveTool.rename(caseOnly)
        check(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains("photo.jpg"), "case-only rename applied")
        let a = folder.appendingPathComponent("a.txt"), b = folder.appendingPathComponent("b.txt")
        try "A".write(to: a, atomically: true, encoding: .utf8)
        try "B".write(to: b, atomically: true, encoding: .utf8)
        try ArchiveTool.rename([RenameStep(from: a, to: b), RenameStep(from: b, to: a)])
        let (nowA, nowB) = (try String(contentsOf: a, encoding: .utf8), try String(contentsOf: b, encoding: .utf8))
        check(nowA == "B" && nowB == "A", "swap in one batch")
        // Review focus 5: path characters in the pattern.
        let slash = ArchiveTool.renamePreview([a], pattern: RenamePattern(newName: "2026/10:08"))
        check(slash[0].to.lastPathComponent == "2026-10-08 1.txt", "slash and colon become dashes")
    }
}
