import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

enum PDFTool {
    /// Images inside re-saved as JPEG (quality 0.7) at no more than 150 dpi, the way Preview's
    /// "Reduce File Size" works; text and vectors stay as they are. (PDFKit's own
    /// saveImagesAsJPEG / optimizeImagesForScreen options leave the file unchanged here.)
    static func compress(_ source: URL, cancel: CancelToken) throws -> URL {
        let doc = try open(source)
        let final = OutputNaming.next(to: source, suffix: "compressed", ext: "pdf")
        guard let filter = QuartzFilter(properties: compressFilter) else { throw FileToolError.failed("Couldn't set up PDF compression") }
        return try write(doc, to: final, options: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter], cancel: cancel)
    }

    private static let compressFilter: [String: Any] = [
        "Domains": ["Applications": true, "Printing": true],
        "FilterType": 1,
        "Name": "win-tab compress",
        "FilterData": ["ColorSettings": ["ImageSettings": [
            "Compression Quality": 0.7,
            "ImageCompression": "ImageJPEGCompress",
            "ImageScaleSettings": ["ImageResolution": 150, "ImageScaleFactor": 0.0, "ImageScaleInterpolate": true,
                                   "ImageSizeMax": 0, "ImageSizeMin": 0],
        ]]],
    ]

    /// Pages of every PDF in the order given, as `Merged.pdf` beside the first.
    static func merge(_ sources: [URL], cancel: CancelToken) throws -> URL {
        guard sources.count >= 2 else { throw FileToolError.unsupported("Pick two or more PDFs to merge") }
        let out = PDFDocument()
        for url in sources {
            try cancel.check()
            let doc = try open(url)
            for i in 0..<doc.pageCount { if let page = doc.page(at: i) { out.insert(page, at: out.pageCount) } }
        }
        let final = OutputNaming.unique(in: sources[0].deletingLastPathComponent(), base: "Merged", ext: "pdf")
        return try write(out, to: final, options: [:], cancel: cancel)
    }

    /// One page per image, long edge 842 pt (A4), images read at most 2480 px (A4 at 300 dpi).
    static func imagesToPDF(_ sources: [URL], cancel: CancelToken) throws -> URL {
        let final = OutputNaming.unique(in: sources[0].deletingLastPathComponent(), base: "Images", ext: "pdf")
        let partial = OutputNaming.partial(for: final)
        defer { try? FileManager.default.removeItem(at: partial) }
        var a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(partial as CFURL, mediaBox: &a4, nil) else { throw FileToolError.failed("Couldn't create the PDF") }
        for url in sources {
            try cancel.check()
            try autoreleasepool {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 2480]
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                    throw FileToolError.unreadable(url.lastPathComponent)
                }
                let scale = 842 / CGFloat(max(image.width, image.height))
                var page = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                ctx.beginPage(mediaBox: &page)
                ctx.draw(image, in: page)
                ctx.endPage()
            }
        }
        ctx.closePDF()
        return try OutputNaming.commit(partial, to: final)
    }

    /// Each page as `page N.png` at 144 dpi in a `<name> pages` folder; rotated pages come out upright.
    static func toImages(_ source: URL, cancel: CancelToken) throws -> URL {
        guard let doc = CGPDFDocument(source as CFURL) else { throw FileToolError.unreadable(source.lastPathComponent) }
        guard doc.isUnlocked else { throw FileToolError.unsupported("This PDF is password-protected") }
        let stem = source.deletingPathExtension().lastPathComponent
        let folder = OutputNaming.unique(in: source.deletingLastPathComponent(), base: "\(stem) pages", ext: "")
        let partial = OutputNaming.partial(for: folder)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: partial) }
        for n in 1...max(doc.numberOfPages, 1) {
            try cancel.check()
            try autoreleasepool {
                guard let page = doc.page(at: n) else { return }
                let box = page.getBoxRect(.mediaBox)
                let sideways = page.rotationAngle % 180 != 0
                let w = Int((sideways ? box.height : box.width) * 2), h = Int((sideways ? box.width : box.height) * 2)
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                    throw FileToolError.failed("Not enough memory")
                }
                let rect = CGRect(x: 0, y: 0, width: w, height: h)
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(rect)
                ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
                ctx.drawPDFPage(page)
                let file = partial.appendingPathComponent("page \(n).png")
                guard let image = ctx.makeImage(),
                      let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw FileToolError.failed("Couldn't render page \(n)")
                }
                CGImageDestinationAddImage(dest, image, nil)
                guard CGImageDestinationFinalize(dest) else { throw FileToolError.failed("Couldn't save page \(n)") }
            }
        }
        return try OutputNaming.commit(partial, to: folder)
    }

    private static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw FileToolError.unreadable(url.lastPathComponent) }
        guard !doc.isLocked else { throw FileToolError.unsupported("\(url.lastPathComponent) is password-protected") }
        return doc
    }

    private static func write(_ doc: PDFDocument, to final: URL, options: [PDFDocumentWriteOption: Any], cancel: CancelToken) throws -> URL {
        let partial = OutputNaming.partial(for: final)
        defer { try? FileManager.default.removeItem(at: partial) }
        guard doc.write(to: partial, withOptions: options) else { throw FileToolError.failed("Couldn't write the PDF") }
        try cancel.check()
        return try OutputNaming.commit(partial, to: final)
    }
}
