import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image convert, compress, resize and metadata strip with ImageIO. Never decodes larger than
/// the result needs: resizing reads a downsampled thumbnail, converting copies from the source.
enum ImageTool {
    static func run(_ op: FileOperation, source: URL, options: FileToolOptions, cancel: CancelToken) throws -> URL {
        try cancel.check()
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw FileToolError.unreadable(source.lastPathComponent)
        }
        let current = ImageFormat.of((CGImageSourceGetType(src) as String?).flatMap { UTType($0) })
        let hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let longest = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let job = Job(src: src, source: source, quality: options.quality, hasAlpha: hasAlpha, longest: longest, cancel: cancel)
        switch op {
        case .convertImage(let format):
            return try job.write(format, suffix: nil, maxEdge: nil)
        case .compressImage:
            // Lossy formats stay as they are; lossless ones (PNG, TIFF…) only shrink much as HEIC.
            let format = current.flatMap { $0.isLossy ? $0 : nil } ?? .heic
            return try job.write(format, suffix: "compressed", maxEdge: nil)
        case .resizeImage(let edge):
            let format = current ?? (hasAlpha ? .png : .jpeg)
            return try job.write(format, suffix: "\(min(edge, longest))px", maxEdge: edge)
        case .stripMetadata:
            return try job.strip()
        default:
            throw FileToolError.unsupported("\(op.title) doesn't apply to images")
        }
    }

    private struct Job {
        let src: CGImageSource
        let source: URL
        let quality: Double
        let hasAlpha: Bool
        let longest: Int
        let cancel: CancelToken

        func write(_ format: ImageFormat, suffix: String?, maxEdge: Int?) throws -> URL {
            let final = OutputNaming.next(to: source, suffix: suffix, ext: format.fileExtension)
            let partial = OutputNaming.partial(for: final)
            defer { try? FileManager.default.removeItem(at: partial) }
            guard let dest = CGImageDestinationCreateWithURL(partial as CFURL, format.type.identifier as CFString, 1, nil) else {
                throw FileToolError.unsupported("Can't write \(format.label) here")
            }
            var opts: [CFString: Any] = [:]
            if format.isLossy { opts[kCGImageDestinationLossyCompressionQuality] = quality }
            let edge = maxEdge.map { min($0, longest) } ?? longest
            // JPEG has no alpha: ImageIO would leave transparent pixels black.
            let flatten = hasAlpha && format == .jpeg
            if edge < longest || flatten {
                try autoreleasepool {
                    let image = try decode(maxEdge: edge)
                    let output = try flatten ? onWhite(image) : image
                    CGImageDestinationAddImage(dest, output, opts as CFDictionary)
                }
            } else {
                CGImageDestinationAddImageFromSource(dest, src, 0, opts as CFDictionary)
            }
            try cancel.check()
            guard CGImageDestinationFinalize(dest) else { throw FileToolError.failed("Couldn't write \(format.label)") }
            return try OutputNaming.commit(partial, to: final)
        }

        /// Same format, same pixels, no GPS / EXIF / XMP; the orientation is kept so it still shows upright.
        func strip() throws -> URL {
            guard let type = CGImageSourceGetType(src) else { throw FileToolError.unreadable(source.lastPathComponent) }
            let final = OutputNaming.next(to: source, suffix: "no metadata", ext: source.pathExtension)
            let partial = OutputNaming.partial(for: final)
            defer { try? FileManager.default.removeItem(at: partial) }
            guard let dest = CGImageDestinationCreateWithURL(partial as CFURL, type, 1, nil) else {
                throw FileToolError.unsupported("Can't rewrite this image type")
            }
            // The new metadata holds only the orientation (ImageIO refuses kCGImageDestinationOrientation
            // together with kCGImageDestinationMetadata), so a portrait photo still shows upright.
            let metadata = CGImageMetadataCreateMutable()
            if let orientation = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFTypeRef)
            }
            let opts: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ]
            if !CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, nil) {
                OutputNaming.removeImageIOTemporaries(of: partial)
                // Formats CopyImageSource can't rewrite losslessly: re-encode without the dictionaries.
                guard let again = CGImageDestinationCreateWithURL(partial as CFURL, type, 1, nil) else { throw FileToolError.failed("Couldn't strip") }
                let drop: [CFString: Any] = [kCGImagePropertyGPSDictionary: kCFNull as Any, kCGImagePropertyExifDictionary: kCFNull as Any,
                                             kCGImagePropertyIPTCDictionary: kCFNull as Any, kCGImageDestinationLossyCompressionQuality: 0.95]
                CGImageDestinationAddImageFromSource(again, src, 0, drop as CFDictionary)
                guard CGImageDestinationFinalize(again) else { throw FileToolError.failed("Couldn't strip") }
            }
            try cancel.check()
            return try OutputNaming.commit(partial, to: final)
        }

        private func decode(maxEdge: Int) throws -> CGImage {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                throw FileToolError.unreadable(source.lastPathComponent)
            }
            return image
        }

        private func onWhite(_ image: CGImage) throws -> CGImage {
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw FileToolError.failed("Not enough memory")
            }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
            ctx.draw(image, in: rect)
            guard let flat = ctx.makeImage() else { throw FileToolError.failed("Not enough memory") }
            return flat
        }
    }
}
