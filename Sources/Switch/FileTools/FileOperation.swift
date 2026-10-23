import Foundation
import UniformTypeIdentifiers

/// What a file is, for offering the operations that make sense on it.
enum FileKind: Equatable {
    case image, video, audio, pdf, archive, other

    static func of(_ url: URL) -> FileKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .zip) { return .archive }
        return .other
    }
}

/// Image formats ImageIO can write here (it reads WebP but can't write it).
enum ImageFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic, avif, tiff, pdf
    var id: String { rawValue }

    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .avif: return UTType("public.avif") ?? .heic
        case .tiff: return .tiff
        case .pdf: return .pdf
        }
    }

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var label: String { self == .jpeg ? "JPG" : rawValue.uppercased() }
    /// Takes a quality setting.
    var isLossy: Bool { self == .jpeg || self == .heic || self == .avif }

    /// The format a file is already in, if it's one we write (PDF isn't an image source here).
    static func of(_ type: UTType?) -> ImageFormat? {
        guard let type else { return nil }
        return allCases.first { $0 != .pdf && type.conforms(to: $0.type) }
    }
}

enum VideoPreset: String, CaseIterable, Identifiable {
    case hevc1080, h264_1080, h264_720
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hevc1080: return "HEVC 1080p"
        case .h264_1080: return "H.264 1080p"
        case .h264_720: return "H.264 720p"
        }
    }
}

enum VideoContainer: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum FileOperation: Equatable {
    case convertImage(ImageFormat)
    case compressImage
    case resizeImage(maxEdge: Int)
    case stripMetadata
    case compressVideo(VideoPreset)
    case convertVideo(VideoContainer)
    case toAudio
    case compressPDF
    case pdfToImages
    case mergePDFs
    case imagesToPDF
    case zip
    case unzip

    static let resizeEdges = [3840, 2560, 1920, 1280]

    /// One job for all the files instead of one per file.
    var combinesFiles: Bool {
        switch self {
        case .mergePDFs, .imagesToPDF, .zip: return true
        default: return false
        }
    }

    /// Kept only when the result is smaller than the original.
    var mustShrink: Bool {
        switch self {
        case .compressImage, .compressVideo, .compressPDF: return true
        default: return false
        }
    }

    /// One file in, one file of the same kind out: Settings → Replace the original applies.
    var canReplaceOriginal: Bool {
        switch self {
        case .convertImage, .compressImage, .resizeImage, .stripMetadata, .compressVideo, .convertVideo, .compressPDF: return true
        default: return false
        }
    }

    /// Video, PDF and archives run one at a time; images two at a time.
    var isHeavy: Bool {
        switch self {
        case .convertImage, .compressImage, .resizeImage, .stripMetadata: return false
        default: return true
        }
    }

    var title: String {
        switch self {
        case .convertImage(let f): return "To \(f.label)"
        case .compressImage, .compressPDF: return "Compress"
        case .resizeImage(let edge): return "Resize \(edge) px"
        case .stripMetadata: return "Strip info"
        case .compressVideo(let p): return "Compress \(p.label)"
        case .convertVideo(let c): return "To \(c.label)"
        case .toAudio: return "Audio only"
        case .pdfToImages: return "To images"
        case .mergePDFs: return "Merge PDFs"
        case .imagesToPDF: return "Images to PDF"
        case .zip: return "Zip"
        case .unzip: return "Unzip"
        }
    }
}

struct FileToolOptions: Equatable {
    var quality: Double = 0.8
}

struct FileOutcome: Equatable {
    let outputs: [URL]
    let bytesBefore: Int64
    let bytesAfter: Int64
}

enum FileToolError: LocalizedError, Equatable {
    case unreadable(String)
    case unsupported(String)
    case alreadyOptimized
    case noAudio
    case protectedContent
    case diskFull
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Can't read \(name)"
        case .unsupported(let why): return why
        case .alreadyOptimized: return "Already optimized, kept the original"
        case .noAudio: return "This video has no sound"
        case .protectedContent: return "Protected (DRM) media can't be converted"
        case .diskFull: return "Not enough disk space"
        case .cancelled: return "Cancelled"
        case .failed(let why): return why
        }
    }

    /// Disk-full errors from Cocoa, POSIX or AVFoundation (-11807); anything else as its message.
    static func from(_ error: Error) -> FileToolError {
        if let known = error as? FileToolError { return known }
        let ns = error as NSError
        if ns.code == NSFileWriteOutOfSpaceError || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) || ns.code == -11807 {
            return .diskFull
        }
        return .failed(ns.localizedDescription)
    }
}

/// Cancel flag shared by the queue and a running tool; handlers stop work in flight
/// (an export session, a `ditto` process).
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let run = handlers
        handlers = []
        lock.unlock()
        run.forEach { $0() }
    }

    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return }
        handlers.append(handler)
        lock.unlock()
    }

    func check() throws { if isCancelled { throw FileToolError.cancelled } }
}

enum FileSize {
    /// Bytes of files, and of everything inside folders.
    static func of(_ urls: [URL]) -> Int64 {
        urls.reduce(0) { total, url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return total }
            guard isDir.boolValue else { return total + fileSize(url) }
            let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var sum: Int64 = 0
            while let item = items?.nextObject() as? URL { sum += fileSize(item) }
            return total + sum
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
