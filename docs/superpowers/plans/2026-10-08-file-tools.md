# Công cụ file trên notch: kế hoạch triển khai

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thả file lên notch hoặc nhấn ⌃⌥D để đổi định dạng, nén, resize, xoá metadata, xử lý video/âm thanh/PDF, zip và đổi tên hàng loạt. App vẫn nhẹ: RAM lúc rảnh ≤ 70 MB, CPU lúc rảnh ≤ 0.3%.

**Architecture:**
- Lõi `Sources/Switch/FileTools/` chỉ dùng ImageIO, AVFoundation, PDFKit và `ditto`, không đụng UI. Vì vậy `tools/filetools-check.swift` biên dịch và kiểm được lõi độc lập.
- `FileJobQueue` (`@MainActor`) chạy job bằng `Task.detached(priority: .utility)`, giới hạn số việc chạy cùng lúc. Khi không có job thì không có luồng hay timer nào chạy.
- Tab Shelf của notch đổi thành Files: chọn file, thanh thao tác theo loại file, danh sách job.
- ⌃⌥D là một slot mới của event tap có sẵn.

**Tech Stack:** Swift 5 mode, SwiftUI + AppKit, ImageIO, AVFoundation, PDFKit, QuickLookThumbnailing, XcodeGen + xcodebuild.

**Spec:** `docs/superpowers/specs/2026-10-08-file-tools-design.md`

## Global Constraints

- Không thêm thư viện ngoài. Chỉ ImageIO, AVFoundation, PDFKit, QuickLookThumbnailing, `/usr/bin/ditto`.
- Không xuất WebP. Định dạng ảnh xuất được: JPG, PNG, HEIC, AVIF, TIFF, PDF. GIF bị bỏ vì giao diện đã duyệt không có.
- Không bao giờ ghi đè file gốc. "Thay file gốc" mặc định tắt; khi bật, bản cũ vào Thùng rác.
- File kết quả nằm cạnh file gốc, tên thêm hậu tố ` (compressed)` / ` (1920px)` / ` (no metadata)`; trùng tên thì thêm ` 2`, ` 3`.
- Ghi ra file `.<tên>.partial.<đuôi>` trước, xong mới đổi tên. Lỗi hoặc huỷ thì xoá file tạm.
- Thao tác nén chỉ giữ kết quả nếu nhỏ hơn bản gốc; nếu không thì báo "Already optimized, kept the original".
- Chất lượng mặc định 0.8. Resize: 3840/2560/1920/1280 px theo cạnh dài, không phóng to.
- Video: HEVC 1080p (mặc định), H.264 1080p, H.264 720p, xuất `.mp4`.
- PDF → ảnh: PNG 144 dpi. Ảnh → PDF: trang có cạnh dài 842 pt.
- Phím tắt mặc định ⌃⌥D (keyCode 2, Control + Option), đổi được trong Settings → General → Hotkeys.
- Chạy cùng lúc tối đa 2 job ảnh và 1 job nặng (video/PDF/zip). Energy Saver bật thì 1 + 1.
- Tiến độ cập nhật UI tối đa 10 lần/giây.
- Không bao giờ gửi file ra mạng.
- Commit không có trailer AI. Không commit `build/` hay `WinTab.xcodeproj`.
- Sau mỗi lần cài bản build: chuyển `build/Build/Products/*/win-tab.app` vào Thùng rác, để Spotlight chỉ thấy `/Applications/win-tab.app`.

## Review Focus

1. **PNG trong suốt → JPG:** nền phải là trắng, không đen. Test ở Task 3.
2. **Đổi tên chỉ khác hoa/thường hoặc đổi chéo trong một lượt** (`photo.JPG` → `photo.jpg`, `a` ↔ `b`): không được thêm " 2", không được mất file. Test ở Task 5.
3. **File bị xoá hoặc dời đi sau khi đã thả vào Files:** báo "Can't read …" cho riêng file đó, các job khác vẫn chạy. Test ở Task 2.
4. **Video không có tiếng → "Audio only":** báo "This video has no sound", không tạo file rỗng. Test ở Task 4.
5. **Mẫu đổi tên có `/` hoặc `:`:** ký tự được thay bằng `-`, không lỗi. Test ở Task 5.

## File Structure

| File | Tạo/Sửa | Trách nhiệm |
|---|---|---|
| `Sources/Switch/FileTools/FileOperation.swift` | Tạo | `FileKind`, `ImageFormat`, `VideoPreset`, `VideoContainer`, `FileOperation`, `FileToolOptions`, `FileOutcome`, `FileToolError`, `CancelToken`, `FileSize` |
| `Sources/Switch/FileTools/OutputNaming.swift` | Tạo | Tên kết quả, tên file tạm, commit |
| `Sources/Switch/FileTools/ImageTool.swift` | Tạo | Ảnh |
| `Sources/Switch/FileTools/MediaTool.swift` | Tạo | Video, âm thanh |
| `Sources/Switch/FileTools/PDFTool.swift` | Tạo | PDF |
| `Sources/Switch/FileTools/ArchiveTool.swift` | Tạo | Zip, unzip, đổi tên |
| `Sources/Switch/FileTools/FileTools.swift` | Tạo | Điều phối `perform` + `finish` (nhỏ hơn mới giữ, thay file gốc) |
| `Sources/Switch/FileTools/FileJobQueue.swift` | Tạo | Hàng đợi `@MainActor` (không nằm trong bài tự kiểm) |
| `tools/filetools-check.swift` | Tạo | Bài tự kiểm cho lõi |
| `Sources/Switch/Notch/NotchFilesView.swift` | Tạo | Tab Files, ảnh xem trước, dòng job, dòng đổi tên |
| `Sources/Switch/Notch/FinderSelection.swift` | Tạo | Đọc file đang chọn trong Finder |
| `Sources/Switch/Notch/NotchView.swift` | Sửa | Bỏ `NotchShelfView`, đổi nhãn tab thành "Files", dùng `NotchFilesView` |
| `Sources/Switch/Notch/NotchServices.swift` | Sửa | `FileShelf`: thêm `notice`, `replace(_:with:)`, `remove(_:)` |
| `Sources/Switch/Notch/NotchController.swift` | Sửa | `openFiles()` |
| `Sources/Switch/HotkeyConfig.swift`, `HotkeyManager.swift`, `AppDelegate.swift`, `SettingsView.swift` | Sửa | Slot `.fileDrop` ⌃⌥D |
| `Sources/Switch/Notch/NotchSettingsTab.swift` | Sửa | Mục Settings → Notch → Files, đổi nhãn tab |

Lệnh build dùng chung (chạy từ gốc repo):

```bash
xcodegen generate -q && xcodebuild -project WinTab.xcodeproj -scheme WinTab -configuration Release -derivedDataPath build build 2>&1 | grep -E 'error:|BUILD'
```

Lệnh chạy bài tự kiểm lõi (Task 2 trở đi):

```bash
swiftc -parse-as-library -O tools/filetools-check.swift Sources/Switch/FileTools/{FileOperation,OutputNaming,ImageTool,MediaTool,PDFTool,ArchiveTool,FileTools}.swift -o /tmp/filetools-check && /tmp/filetools-check
```

---

### Task 1: Kiểm tra sức khoẻ: RAM và CPU lúc rảnh

**Files:** tuỳ nguyên nhân tìm được. Mục "Kết quả đo" bên dưới ghi file cần sửa.

**Interfaces:** không đổi API.

- [ ] **Step 1: Đo trạng thái hiện tại.** Chạy bản Release với `open --env MallocStackLogging=lite`, để rảnh ít nhất 30 phút, rồi đo:

```bash
P=$(pgrep -x win-tab)
footprint $P | grep -E 'Footprint|Malloc'
heap $P > /tmp/heap-a.txt; sleep 600; heap $P > /tmp/heap-b.txt
diff <(grep -E '^\s+[0-9]+\s+[0-9]+' /tmp/heap-a.txt | awk '{print $4,$5,$6,$1,$2}' | sort) <(grep -E '^\s+[0-9]+\s+[0-9]+' /tmp/heap-b.txt | awk '{print $4,$5,$6,$1,$2}' | sort) | head -40
T1=$(ps -o time= -p $P); sleep 60; T2=$(ps -o time= -p $P); echo "$T1 -> $T2"
```

Expected: biết được loại cấp phát nào tăng giữa hai lần đo, và CPU dùng trong 60 s.

- [ ] **Step 2: Tìm stack cấp phát của loại đang tăng.** Thay `<TYPE>` bằng loại cấp phát tìm được ở Step 1.

```bash
malloc_history $P -allBySize | grep -B2 -A25 '<TYPE>' | head -80
```

Expected: hàm trong win-tab đang giữ bộ nhớ.

- [ ] **Step 3: Sửa đúng nguyên nhân** (theo "Kết quả đo"). Build Release, cài vào `/Applications`, chạy lại Step 1 sau 30 phút. Đạt khi footprint ≤ 70 MB, không tăng giữa hai lần đo cách nhau 10 phút, CPU ≤ 0.18 s trong 60 s khi người dùng không thao tác.

- [ ] **Step 4: Commit** với message dạng `perf: <nguyên nhân> — idle footprint <trước> → <sau> MB`.

**Kết quả đo (2026-10-08):**
- Bản mở sạch: **54 MB** sau 60 s, Malloc Small 36 MB.
- 8 lần mở notch: lên 57 MB. 21 lần ⌘-Tab: dao động 68–99 MB rồi về **78 MB**; Malloc Small dừng ở 51–58 MB. Bộ đệm glyph chữ và ảnh xem trước có trần, không tăng mãi.
- `leaks`: 1 MB, là của hệ thống (kết nối XPC `linkd`).
- Con số 150 MB đo giữa chừng có 64 MB "Performance Tool Data", do win-tab bị mở kèm biến `MallocStackLogging` của shell. Từ giờ luôn mở bằng `env -u MallocStackLogging open …`.
- Kết luận: không có rò rỉ cần sửa ở Step 3. Task 9 đo lại sau một thời gian chạy dài.

---

### Task 2: Kiểu dữ liệu, tên file kết quả, bộ khung bài tự kiểm

**Files:**
- Create: `Sources/Switch/FileTools/FileOperation.swift`
- Create: `Sources/Switch/FileTools/OutputNaming.swift`
- Create: `Sources/Switch/FileTools/FileTools.swift` (khung; các task sau điền thêm `perform`)
- Create: `Sources/Switch/FileTools/{ImageTool,MediaTool,PDFTool,ArchiveTool}.swift`, mỗi file chỉ `import Foundation`
- Create: `tools/filetools-check.swift`

**Interfaces:**
- Produces:
  - `enum FileKind { image, video, audio, pdf, archive, other; static func of(_: URL) -> FileKind }`
  - `enum ImageFormat: String, CaseIterable { jpeg, png, heic, avif, tiff, pdf }`, kèm `type`, `fileExtension`, `label`, `isLossy`, `static func of(_: UTType?) -> ImageFormat?`
  - `enum VideoPreset { hevc1080, h264_1080, h264_720 }`, `enum VideoContainer { mp4, mov }`
  - `enum FileOperation`, kèm `combinesFiles`, `mustShrink`, `canReplaceOriginal`, `isHeavy`, `title`, `static let resizeEdges`
  - `struct FileToolOptions { var quality: Double = 0.8 }`
  - `struct FileOutcome { outputs: [URL]; bytesBefore: Int64; bytesAfter: Int64 }`
  - `enum FileToolError: LocalizedError, Equatable { unreadable(String), unsupported(String), alreadyOptimized, noAudio, protectedContent, diskFull, cancelled, failed(String); static func from(_: Error) -> FileToolError }`
  - `final class CancelToken { isCancelled; cancel(); onCancel(_:); check() throws }`
  - `enum FileSize { static func of(_: [URL]) -> Int64 }`
  - `enum OutputNaming { next(to:suffix:ext:), unique(in:base:ext:), partial(for:), commit(_:to:) }`
  - `enum FileTools { static func perform(_ op: FileOperation, inputs: [URL], options: FileToolOptions, cancel: CancelToken, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL]; static func finish(_ op: FileOperation, inputs: [URL], outputs: [URL], replaceOriginal: Bool) throws -> FileOutcome }`

- [ ] **Step 1: Viết bài tự kiểm (đang FAIL).** Tạo `tools/filetools-check.swift`:

```swift
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

    static func imageChecks() async throws {}
    static func mediaChecks() async throws {}
    static func pdfChecks() async throws {}
    static func archiveChecks() async throws {}
}
```

- [ ] **Step 2: Chạy để thấy FAIL.**

Run: lệnh chạy bài tự kiểm (chưa có file nguồn thì lệnh `swiftc` báo thiếu file).
Expected: lỗi biên dịch "cannot find 'OutputNaming' in scope", hoặc "no such file".

- [ ] **Step 3: Viết `FileOperation.swift`**

```swift
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
```

- [ ] **Step 4: Viết `OutputNaming.swift`**

```swift
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
```

- [ ] **Step 5: Viết khung `FileTools.swift`.** `perform` báo unsupported cho tới khi các task sau điền vào; `finish` làm xong ngay ở task này.

```swift
import Foundation

/// The one entry point the queue (and the self-check) use.
enum FileTools {
    /// Runs `op` and returns what it wrote. A file that vanished since it was shelved fails
    /// on its own with `unreadable`.
    static func perform(_ op: FileOperation, inputs: [URL], options: FileToolOptions, cancel: CancelToken,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        guard !inputs.isEmpty else { throw FileToolError.unsupported("No files") }
        for url in inputs where !FileManager.default.isReadableFile(atPath: url.path) {
            throw FileToolError.unreadable(url.lastPathComponent)
        }
        switch op {
        default:
            throw FileToolError.unsupported("\(op.title) isn't available yet")
        }
    }

    /// Sizes, the keep-only-if-smaller rule, and Settings → Replace the original (the original
    /// goes to the Trash; the result takes its name when the extension matches).
    static func finish(_ op: FileOperation, inputs: [URL], outputs: [URL], replaceOriginal: Bool) throws -> FileOutcome {
        let before = FileSize.of(inputs)
        let after = FileSize.of(outputs)
        if op.mustShrink && after >= before {
            outputs.forEach { try? FileManager.default.removeItem(at: $0) }
            throw FileToolError.alreadyOptimized
        }
        guard replaceOriginal, op.canReplaceOriginal, let original = inputs.first, let output = outputs.first else {
            return FileOutcome(outputs: outputs, bytesBefore: before, bytesAfter: after)
        }
        try FileManager.default.trashItem(at: original, resultingItemURL: nil)
        guard output.pathExtension.lowercased() == original.pathExtension.lowercased() else {
            return FileOutcome(outputs: [output], bytesBefore: before, bytesAfter: after)
        }
        try FileManager.default.moveItem(at: output, to: original)
        return FileOutcome(outputs: [original], bytesBefore: before, bytesAfter: after)
    }
}
```

- [ ] **Step 6: Tạo 4 file tool rỗng** (`ImageTool.swift`, `MediaTool.swift`, `PDFTool.swift`, `ArchiveTool.swift`), mỗi file chỉ có dòng `import Foundation`.

- [ ] **Step 7: Chạy bài tự kiểm.** Expected: `PASS 7 checks`.

- [ ] **Step 8: Build app** (lệnh build chung). Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Sources/Switch/FileTools tools/filetools-check.swift
git commit -m "feat(files): operation types, output naming and core self-check"
```

---

### Task 3: Ảnh (đổi định dạng, nén, resize, xoá metadata)

**Files:**
- Modify: `Sources/Switch/FileTools/ImageTool.swift`
- Modify: `Sources/Switch/FileTools/FileTools.swift` (nhánh ảnh)
- Modify: `tools/filetools-check.swift` (`imageChecks`)

**Interfaces:**
- Consumes: `FileOperation`, `FileToolOptions`, `CancelToken`, `OutputNaming`, `ImageFormat`
- Produces: `enum ImageTool { static func run(_ op: FileOperation, source: URL, options: FileToolOptions, cancel: CancelToken) throws -> URL }`

- [ ] **Step 1: Viết test (FAIL).** Thay `static func imageChecks() async throws {}` bằng:

```swift
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
        check(leftovers.isEmpty, "no partial files left")
    }
```

- [ ] **Step 2: Chạy để thấy FAIL.** Expected: chương trình dừng ở lỗi "To JPG isn't available yet", do `perform` ném lỗi chưa bắt.

- [ ] **Step 3: Viết `ImageTool.swift`** (thay nội dung file):

```swift
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
```

- [ ] **Step 4: Nối vào `FileTools.perform`.** Thêm trước `default:`:

```swift
        case .convertImage, .compressImage, .resizeImage, .stripMetadata:
            return [try ImageTool.run(op, source: inputs[0], options: options, cancel: cancel)]
```

- [ ] **Step 5: Chạy bài tự kiểm.** Expected: không có dòng `FAIL`; dòng cuối `PASS 22 checks`.
- [ ] **Step 6: Build app.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 7: Commit**

```bash
git add Sources/Switch/FileTools tools/filetools-check.swift
git commit -m "feat(files): image convert, compress, resize and metadata strip"
```

---

### Task 4: Video và âm thanh

**Files:**
- Modify: `Sources/Switch/FileTools/MediaTool.swift`
- Modify: `Sources/Switch/FileTools/FileTools.swift`
- Modify: `tools/filetools-check.swift` (`mediaChecks`)

**Interfaces:**
- Produces: `enum MediaTool { static func run(_ op: FileOperation, source: URL, cancel: CancelToken, progress: @escaping @Sendable (Double) -> Void) async throws -> URL }`, `VideoContainer.fileType`, `VideoPreset.avPreset`

- [ ] **Step 1: Viết test (FAIL).** Thay `static func mediaChecks() async throws {}` bằng:

```swift
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
```

- [ ] **Step 2: Chạy để thấy FAIL.** Expected: dừng ở lỗi "Compress HEVC 1080p isn't available yet".

- [ ] **Step 3: Viết `MediaTool.swift`** (thay nội dung file):

```swift
import AVFoundation
import Foundation

extension VideoContainer {
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

extension VideoPreset {
    var avPreset: String {
        switch self {
        case .hevc1080: return AVAssetExportPresetHEVC1920x1080
        case .h264_1080: return AVAssetExportPreset1920x1080
        case .h264_720: return AVAssetExportPreset1280x720
        }
    }
}

/// Video and audio through AVAssetExportSession. Encoding runs in the system's media services,
/// so win-tab itself stays small while a long video exports.
enum MediaTool {
    static func run(_ op: FileOperation, source: URL, cancel: CancelToken, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try cancel.check()
        let asset = AVURLAsset(url: source)
        let readable = (try? await asset.load(.isReadable)) ?? false
        guard readable else { throw FileToolError.unreadable(source.lastPathComponent) }
        if try await asset.load(.hasProtectedContent) { throw FileToolError.protectedContent }

        let config: (preset: String, fileType: AVFileType, suffix: String?, ext: String)
        switch op {
        case .compressVideo(let p):
            config = (p.avPreset, .mp4, "compressed", "mp4")
        case .convertVideo(let c):
            config = (AVAssetExportPresetPassthrough, c.fileType, nil, c.rawValue)
        case .toAudio:
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw FileToolError.noAudio }
            config = (AVAssetExportPresetAppleM4A, .m4a, nil, "m4a")
        default:
            throw FileToolError.unsupported("\(op.title) doesn't apply to video")
        }

        var preset = config.preset
        if !(await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: config.fileType)) {
            // Passthrough can't put every codec in every container: re-encode at full quality instead.
            guard case .convertVideo = op,
                  await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetHighestQuality, with: asset, outputFileType: config.fileType) else {
                throw FileToolError.unsupported("This file can't be made into \(config.ext.uppercased())")
            }
            preset = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw FileToolError.unsupported("This file can't be exported")
        }
        let final = OutputNaming.next(to: source, suffix: config.suffix, ext: config.ext)
        let partial = OutputNaming.partial(for: final)
        defer { try? FileManager.default.removeItem(at: partial) }
        session.outputURL = partial
        session.outputFileType = config.fileType
        session.shouldOptimizeForNetworkUse = true
        cancel.onCancel { session.cancelExport() }
        try await export(session, progress: progress)
        try cancel.check()
        return try OutputNaming.commit(partial, to: final)
    }

    /// Reports progress four times a second while the export runs, and only then.
    private static func export(_ session: AVAssetExportSession, progress: @escaping @Sendable (Double) -> Void) async throws {
        let ticker = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        ticker.schedule(deadline: .now(), repeating: 0.25)
        ticker.setEventHandler { progress(Double(session.progress)) }
        ticker.resume()
        defer { ticker.cancel() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            throw FileToolError.cancelled
        default:
            throw session.error.map(FileToolError.from) ?? FileToolError.failed("Export failed")
        }
    }
}
```

- [ ] **Step 4: Nối vào `FileTools.perform`.** Thêm trước `default:`:

```swift
        case .compressVideo, .convertVideo, .toAudio:
            return [try await MediaTool.run(op, source: inputs[0], cancel: cancel, progress: progress)]
```

- [ ] **Step 5: Chạy bài tự kiểm.** Expected: không có `FAIL`; dòng cuối `PASS 30 checks`.

Nếu báo `FAIL cancel must stop the export`, nghĩa là export 720p xong trong chưa tới 100 ms. Khi đó tăng số khung trong `makeVideo` từ 150 lên 300 rồi chạy lại.

- [ ] **Step 6: Build app.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 7: Commit**

```bash
git add Sources/Switch/FileTools tools/filetools-check.swift
git commit -m "feat(files): video compress and convert, audio to M4A"
```

---

### Task 5: PDF, zip và đổi tên hàng loạt

**Files:**
- Modify: `Sources/Switch/FileTools/PDFTool.swift`, `Sources/Switch/FileTools/ArchiveTool.swift`, `Sources/Switch/FileTools/FileTools.swift`
- Modify: `tools/filetools-check.swift` (`pdfChecks`, `archiveChecks`)

**Interfaces:**
- Produces:
  - `enum PDFTool { static func compress(_ source: URL, cancel: CancelToken) throws -> URL; merge(_ sources: [URL], cancel:) throws -> URL; imagesToPDF(_ sources: [URL], cancel:) throws -> URL; toImages(_ source: URL, cancel:) throws -> URL }`
  - `enum ArchiveTool { zip(_ sources: [URL], cancel:) throws -> URL; unzip(_ source: URL, cancel:) throws -> URL; renamePreview(_ sources: [URL], pattern: RenamePattern) -> [RenameStep]; rename(_ steps: [RenameStep]) throws -> [RenameStep]; undo(_ applied: [RenameStep]) throws }`
  - `struct RenamePattern { var newName = ""; var start = 1; var find = ""; var replace = ""; var newExtension = "" }`
  - `struct RenameStep { let from: URL; let to: URL }`

- [ ] **Step 1: Viết test (FAIL).** Thay `pdfChecks` và `archiveChecks`:

```swift
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
```

- [ ] **Step 2: Chạy để thấy FAIL.** Expected: lỗi biên dịch "cannot find 'ArchiveTool' in scope".

- [ ] **Step 3: Viết `PDFTool.swift`** (thay nội dung file):

```swift
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
```

Nếu trình biên dịch báo kiểu tham số `withOptions` khác `[PDFDocumentWriteOption: Any]`, đổi kiểu của tham số `options` trong `write(_:to:options:cancel:)` cho khớp với SDK.

- [ ] **Step 4: Viết `ArchiveTool.swift`** (thay nội dung file):

```swift
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
```

- [ ] **Step 5: Nối vào `FileTools.perform`.** Thay `default:` bằng các nhánh còn lại; khi đó `switch` đủ mọi case nên bỏ hẳn `default`:

```swift
        case .compressPDF:
            return [try PDFTool.compress(inputs[0], cancel: cancel)]
        case .pdfToImages:
            return [try PDFTool.toImages(inputs[0], cancel: cancel)]
        case .mergePDFs:
            return [try PDFTool.merge(inputs, cancel: cancel)]
        case .imagesToPDF:
            return [try PDFTool.imagesToPDF(inputs, cancel: cancel)]
        case .zip:
            return [try ArchiveTool.zip(inputs, cancel: cancel)]
        case .unzip:
            return [try ArchiveTool.unzip(inputs[0], cancel: cancel)]
```

- [ ] **Step 6: Chạy bài tự kiểm.** Expected: không có `FAIL`; dòng cuối `PASS 45 checks`.
- [ ] **Step 7: Build app.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 8: Commit**

```bash
git add Sources/Switch/FileTools tools/filetools-check.swift
git commit -m "feat(files): PDF compress/merge/convert, zip, unzip and batch rename"
```

---

### Task 6: Hàng đợi job

**Files:**
- Create: `Sources/Switch/FileTools/FileJobQueue.swift`

**Interfaces:**
- Consumes: `FileTools.perform`, `FileTools.finish`, `CancelToken`, `FileOperation`, `EnergySaver.isOn` (app)
- Produces:
  - `FileJobQueue.shared`, `qualityKey = "switch.files.quality"` (Double, 0.8), `replaceOriginalKey = "switch.files.replaceOriginal"` (Bool, false)
  - `enum State { waiting, running(Double), done(FileOutcome), failed(String), cancelled; var isFinished: Bool }`
  - `struct Job: Identifiable { id, operation, inputs, state, title }`
  - `@Published private(set) var jobs: [Job]`
  - `enqueue(_:files:)`, `cancel(_:)`, `clearFinished()`, `isBusy`

- [ ] **Step 1: Viết `FileJobQueue.swift`**

```swift
import Foundation
import QuartzCore

/// File jobs for the notch's Files tab. Jobs run off the main thread at utility priority, at
/// most two images and one video/PDF/archive at a time (one of each with Energy Saver), so
/// ⌘-Tab and animations never wait on them. With no job, nothing here runs.
@MainActor
final class FileJobQueue: ObservableObject {
    static let shared = FileJobQueue()
    static let qualityKey = "switch.files.quality"
    static let replaceOriginalKey = "switch.files.replaceOriginal"

    enum State: Equatable {
        case waiting, running(Double), done(FileOutcome), failed(String), cancelled

        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let operation: FileOperation
        let inputs: [URL]
        var state: State = .waiting
        var title: String { inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) files" }
    }

    @Published private(set) var jobs: [Job] = []
    private var tokens: [UUID: CancelToken] = [:]
    private var progressShownAt: [UUID: CFTimeInterval] = [:]
    /// The UI shows progress at most this often.
    private static let progressInterval: CFTimeInterval = 0.1

    var isBusy: Bool { jobs.contains { !$0.state.isFinished } }

    func enqueue(_ op: FileOperation, files: [URL]) {
        guard !files.isEmpty else { return }
        let groups = op.combinesFiles ? [files] : files.map { [$0] }
        jobs += groups.map { Job(operation: op, inputs: $0) }
        pump()
    }

    func cancel(_ id: UUID) {
        if let token = tokens[id] {
            token.cancel()
        } else {
            update(id) { if $0.state == .waiting { $0.state = .cancelled } }
        }
    }

    func clearFinished() { jobs.removeAll { $0.state.isFinished } }

    private func pump() {
        let saving = EnergySaver.isOn
        for job in jobs where job.state == .waiting {
            let running = jobs.filter {
                if case .running = $0.state { return $0.operation.isHeavy == job.operation.isHeavy }
                return false
            }.count
            let limit = job.operation.isHeavy || saving ? 1 : 2
            if running < limit { start(job) }
        }
    }

    private func start(_ job: Job) {
        update(job.id) { $0.state = .running(0) }
        let token = CancelToken()
        tokens[job.id] = token
        let defaults = UserDefaults.standard
        let options = FileToolOptions(quality: defaults.object(forKey: Self.qualityKey) as? Double ?? 0.8)
        let replace = defaults.bool(forKey: Self.replaceOriginalKey)
        let id = job.id
        Task.detached(priority: .utility) { [weak self] in
            let result: Result<FileOutcome, FileToolError>
            do {
                let outputs = try await FileTools.perform(job.operation, inputs: job.inputs, options: options, cancel: token) { p in
                    Task { @MainActor in self?.progress(id, p) }
                }
                result = .success(try FileTools.finish(job.operation, inputs: job.inputs, outputs: outputs, replaceOriginal: replace))
            } catch {
                result = .failure(FileToolError.from(error))
            }
            await MainActor.run { self?.finish(id, result) }
        }
    }

    private func progress(_ id: UUID, _ value: Double) {
        let now = CACurrentMediaTime()
        guard now - (progressShownAt[id] ?? 0) >= Self.progressInterval else { return }
        progressShownAt[id] = now
        update(id) { if case .running = $0.state { $0.state = .running(min(max(value, 0), 1)) } }
    }

    private func finish(_ id: UUID, _ result: Result<FileOutcome, FileToolError>) {
        tokens[id] = nil
        progressShownAt[id] = nil
        update(id) {
            switch result {
            case .success(let outcome): $0.state = .done(outcome)
            case .failure(.cancelled): $0.state = .cancelled
            case .failure(let error): $0.state = .failed(error.errorDescription ?? "Failed")
            }
        }
        pump()
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }
}
```

- [ ] **Step 2: Build app.** Expected: `** BUILD SUCCEEDED **`. Hàng đợi được kiểm ở Task 7 qua giao diện; phần xử lý thật nằm trong `FileTools`, đã được bài tự kiểm bao.
- [ ] **Step 3: Commit**

```bash
git add Sources/Switch/FileTools/FileJobQueue.swift
git commit -m "feat(files): background job queue with limits and progress"
```

---

### Task 7: Tab Files trên notch

**Files:**
- Create: `Sources/Switch/Notch/NotchFilesView.swift`
- Modify: `Sources/Switch/Notch/NotchView.swift`:
  - `NotchTab.label`: `.shelf` thành "Files".
  - Dòng `case .shelf: NotchShelfView()` thành `case .shelf: NotchFilesView(state: state)`.
  - Xoá `private struct NotchShelfView`.
- Modify: `Sources/Switch/Notch/NotchServices.swift`: `FileShelf` thêm `notice`, `replace(_:with:)`, `remove(_:)`.
- Modify: `Sources/Switch/Notch/NotchSettingsTab.swift`: đổi tab toggle "Shelf tab" thành "Files tab".

**Interfaces:**
- Consumes: `FileShelf.shared`, `FileJobQueue.shared`, `FileKind.of`, `ImageFormat`, `VideoPreset`, `VideoContainer`, `FileOperation.resizeEdges`, `ArchiveTool.renamePreview/rename/undo`, `RenamePattern`, `RenameStep`, `NotchState.replying`, `NowPlayingMonitor.automationSettings`
- Produces: `struct NotchFilesView: View { init(state: NotchState) }`, `final class FileThumbnails`

- [ ] **Step 1: Thêm vào `FileShelf`** (trong `NotchServices.swift`, sau `func clear()`):

```swift
    /// A one-line note for the Files tab (e.g. Finder needs Automation access).
    @Published var notice: String?

    /// After a rename, the shelf keeps pointing at the file under its new name.
    func replace(_ old: URL, with new: URL) {
        guard let i = urls.firstIndex(of: old) else { return }
        urls[i] = new
        save()
    }

    func remove(_ some: Set<URL>) {
        urls = urls.filter { !some.contains($0) }
        save()
    }
```

- [ ] **Step 2: Viết `NotchFilesView.swift`**

```swift
import AppKit
import QuickLookThumbnailing
import SwiftUI

/// QuickLook thumbnails for the Files tab: made at twice the tile size, at most 50 kept.
@MainActor
final class FileThumbnails: ObservableObject {
    static let shared = FileThumbnails()
    private let cache = NSCache<NSURL, NSImage>()
    private var pending = Set<URL>()
    @Published private(set) var version = 0
    private static let side: CGFloat = 36

    private init() { cache.countLimit = 50 }

    func image(for url: URL) -> NSImage {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        request(url)
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func request(_ url: URL) {
        guard !pending.contains(url) else { return }
        pending.insert(url)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: Self.side, height: Self.side), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending.remove(url)
                    guard let image else { return }
                    self.cache.setObject(image, forKey: url as NSURL)
                    self.version += 1
                }
            }
        }
    }
}

/// The notch's Files tab: dropped (or ⌃⌥D Finder-selected) files, an action bar for what fits
/// the selection, and the jobs running or done.
struct NotchFilesView: View {
    @ObservedObject var state: NotchState
    @ObservedObject private var shelf = FileShelf.shared
    @ObservedObject private var queue = FileJobQueue.shared
    @ObservedObject private var thumbnails = FileThumbnails.shared
    @State private var selection = Set<URL>()
    @State private var renaming = false
    @State private var pattern = RenamePattern()
    @State private var lastRename: [RenameStep] = []
    @FocusState private var nameFocused: Bool

    /// Selected files, or all when none are selected.
    private var targets: [URL] {
        let picked = shelf.urls.filter(selection.contains)
        return picked.isEmpty ? shelf.urls : picked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = shelf.notice { noticeRow(notice) }
            if shelf.urls.isEmpty {
                dropZone
            } else {
                tiles
                if renaming { renameRow } else { actionBar }
                if !queue.jobs.isEmpty { jobList }
            }
        }
        .onChange(of: shelf.urls) { _, urls in selection = selection.intersection(urls) }
    }

    // MARK: - Drop zone and tiles

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 22))
                    Text("Drop files here to convert, compress or zip them").font(.system(size: 12))
                    Text("⌃⌥D opens this with the files selected in Finder").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                .foregroundStyle(.white.opacity(0.55))
            }
    }

    private var tiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(shelf.urls, id: \.self) { tile($0) }
            }
        }
        .frame(height: 64)
    }

    private func tile(_ url: URL) -> some View {
        let picked = selection.contains(url)
        _ = thumbnails.version
        return VStack(spacing: 3) {
            Image(nsImage: thumbnails.image(for: url)).resizable().aspectRatio(contentMode: .fit).frame(width: 36, height: 36)
            Text(url.lastPathComponent).font(.system(size: 9)).lineLimit(1).truncationMode(.middle).frame(width: 60)
        }
        .frame(width: 66, height: 62)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(picked ? 0.2 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.accentColor.opacity(picked ? 0.9 : 0), lineWidth: 1.5))
        .overlay(alignment: .topLeading) {
            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11)).foregroundStyle(picked ? Color.accentColor : .white.opacity(0.35)).padding(3)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onTapGesture { if picked { selection.remove(url) } else { selection.insert(url) } }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help("\(url.path)\nClick to select · double-click to open · drag out to use")
    }

    // MARK: - Actions

    private var actionBar: some View {
        let files = targets
        let kinds = Set(files.map(FileKind.of))
        let only = kinds.count == 1 ? kinds.first : nil
        return HStack(spacing: 5) {
            Text(selection.isEmpty ? "All \(files.count)" : "\(files.count) selected")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).frame(width: 62, alignment: .leading)
            switch only {
            case .image:
                menu("Convert", ImageFormat.allCases.map { ($0.label, FileOperation.convertImage($0)) }, files)
                button("Compress", .compressImage, files)
                menu("Resize", FileOperation.resizeEdges.map { ("\($0) px", FileOperation.resizeImage(maxEdge: $0)) }, files)
                button("Strip info", .stripMetadata, files)
                button("PDF", .imagesToPDF, files)
            case .video:
                menu("Compress", VideoPreset.allCases.map { ($0.label, FileOperation.compressVideo($0)) }, files)
                menu("Convert", VideoContainer.allCases.map { ($0.label, FileOperation.convertVideo($0)) }, files)
                button("Audio only", .toAudio, files)
            case .audio:
                button("To M4A", .toAudio, files)
            case .pdf:
                button("Compress", .compressPDF, files)
                if files.count > 1 { button("Merge", .mergePDFs, files) }
                button("To images", .pdfToImages, files)
            case .archive:
                button("Unzip", .unzip, files)
            default:
                EmptyView()
            }
            button("Zip", .zip, files)
            pill("Rename") { startRename() }
            Spacer(minLength: 0)
            more
        }
        .frame(height: 22)
    }

    private func button(_ title: String, _ op: FileOperation, _ files: [URL]) -> some View {
        pill(title) { queue.enqueue(op, files: files) }
    }

    private func menu(_ title: String, _ items: [(String, FileOperation)], _ files: [URL]) -> some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(item.0) { queue.enqueue(item.1, files: files) }
            }
        } label: {
            Text(title + " ▾").font(.system(size: 10.5, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private var more: some View {
        Menu {
            Button("Select all") { selection = Set(shelf.urls) }
            Button("Select none") { selection = [] }
            Divider()
            Button(selection.isEmpty ? "Remove all from Files" : "Remove selected from Files") {
                if selection.isEmpty { shelf.clear() } else { shelf.remove(selection) }
                selection = []
            }
            if queue.jobs.contains(where: { $0.state.isFinished }) { Button("Clear finished jobs") { queue.clearFinished() } }
            if !lastRename.isEmpty { Button("Undo last rename") { undoRename() } }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Rename

    private var renameRow: some View {
        let preview = ArchiveTool.renamePreview(targets, pattern: pattern)
        return HStack(spacing: 5) {
            field("New name (blank keeps)", $pattern.newName, width: 130).focused($nameFocused)
            field("Find", $pattern.find, width: 64)
            field("Replace", $pattern.replace, width: 64)
            field("ext", $pattern.newExtension, width: 38)
            Text(preview.first.map { "→ " + $0.to.lastPathComponent + (preview.count > 1 ? " …" : "") } ?? "")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            pill("Apply") { applyRename(preview) }
            pill("Cancel") { endRename() }
        }
        .frame(height: 22)
        .onExitCommand { endRename() }
    }

    private func field(_ title: String, _ text: Binding<String>, width: CGFloat) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain).font(.system(size: 10.5))
            .padding(.horizontal, 6).frame(width: width, height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
    }

    private func startRename() {
        pattern = RenamePattern()
        renaming = true
        state.replying = true
        // The panel becomes key on the next turn; focus after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true }
    }

    private func endRename() {
        renaming = false
        nameFocused = false
        if state.replying { state.replying = false }
    }

    private func applyRename(_ preview: [RenameStep]) {
        do {
            let applied = try ArchiveTool.rename(preview)
            applied.forEach { shelf.replace($0.from, with: $0.to) }
            selection = Set(selection.map { url in applied.first { $0.from == url }?.to ?? url })
            lastRename = applied
            shelf.notice = applied.isEmpty ? nil : "Renamed \(applied.count) · Undo is in the ⋯ menu"
            endRename()
        } catch {
            shelf.notice = FileToolError.from(error).errorDescription
        }
    }

    private func undoRename() {
        do {
            try ArchiveTool.undo(lastRename)
            lastRename.forEach { shelf.replace($0.to, with: $0.from) }
            lastRename = []
            shelf.notice = nil
        } catch {
            shelf.notice = FileToolError.from(error).errorDescription
        }
    }

    // MARK: - Jobs and notices

    private var jobList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(queue.jobs.reversed()) { JobRow(job: $0) }
            }
        }
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
            Text(text).lineLimit(1)
            if text.contains("Automation") {
                Button("Open") { NSWorkspace.shared.open(NowPlayingMonitor.automationSettings) }.buttonStyle(.plain).underline()
            }
            Spacer(minLength: 0)
            Button { shelf.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.orange)
        .frame(height: 16)
    }
}

/// One job: what, on which file, then progress, the size change or the error.
private struct JobRow: View {
    let job: FileJobQueue.Job

    var body: some View {
        HStack(spacing: 6) {
            icon.frame(width: 14)
            Text(job.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
            Text(job.operation.title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            Spacer(minLength: 4)
            status
        }
        .frame(height: 20)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.white.opacity(0.5))
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .waiting, .running:
            ProgressView(value: Self.fraction(job.state)).progressViewStyle(.linear).frame(width: 90)
            Button { FileJobQueue.shared.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("Cancel")
        case .done(let outcome):
            Text(Self.change(outcome)).font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting(outcome.outputs) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Show in Finder")
        case .failed(let message):
            Text(message).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
        case .cancelled:
            Text("Cancelled").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
        }
    }

    static func fraction(_ state: FileJobQueue.State) -> Double {
        if case .running(let p) = state { return p }
        return 0
    }

    /// "2.4 MB → 640 KB (−73%)".
    static func change(_ o: FileOutcome) -> String {
        let f = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        guard o.bytesBefore > 0 else { return f(o.bytesAfter) }
        let pct = Int((Double(o.bytesAfter - o.bytesBefore) / Double(o.bytesBefore) * 100).rounded())
        return "\(f(o.bytesBefore)) → \(f(o.bytesAfter)) (\(pct > 0 ? "+" : "")\(pct)%)"
    }
}
```

- [ ] **Step 3: Sửa `NotchView.swift`.**
  - Đổi `var label: String { rawValue.capitalized }` thành `var label: String { self == .shelf ? "Files" : rawValue.capitalized }`.
  - Đổi `case .shelf: NotchShelfView()` thành `case .shelf: NotchFilesView(state: state)`.
  - Xoá toàn bộ `private struct NotchShelfView: View { … }`.
- [ ] **Step 4: Sửa `NotchSettingsTab.swift`.** Đổi `tabToggle("shelf", "Shelf tab", "Files dropped on the notch.")` thành `tabToggle("shelf", "Files tab", "Files dropped on the notch: convert, compress, resize, PDF, zip and rename them.")`.
- [ ] **Step 5: Build app.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Kiểm tra trên giao diện.** Cài bản build, thả 2 ảnh mẫu và 1 video mẫu vào notch. Dùng probe có quyền (ký giống win-tab) để chụp tab Files ở 4 trạng thái: trống, đã chọn, đang chạy, có kết quả. Đạt khi:
  - các dòng vừa khung 580 × 158 pt;
  - thanh thao tác đổi theo loại file đang chọn;
  - kết quả hiện "… → … (−…%)";
  - kính lúp mở Finder ở đúng file.
- [ ] **Step 7: Commit**

```bash
git add Sources/Switch/Notch Sources/Switch/FileTools
git commit -m "feat(files): Files tab on the notch with actions, jobs and rename"
```

---

### Task 8: Phím ⌃⌥D, file đang chọn trong Finder, Settings

**Files:**
- Create: `Sources/Switch/Notch/FinderSelection.swift`
- Modify: `Sources/Switch/HotkeyConfig.swift`, `Sources/Switch/HotkeyManager.swift`, `Sources/Switch/AppDelegate.swift`, `Sources/Switch/SettingsView.swift`
- Modify: `Sources/Switch/Notch/NotchController.swift` (`openFiles()`)
- Modify: `Sources/Switch/Notch/NotchSettingsTab.swift` (mục Files)

**Interfaces:**
- Produces:
  - `HotkeyConfig.Slot.fileDrop`, `HotkeyBinding.defaultFileDrop`
  - `HotkeyManager.onFileDrop: (() -> Void)?`
  - `NotchController.openFiles()`
  - `@MainActor enum FinderSelection { static func read(_ done: @escaping @MainActor ([URL]?) -> Void) }`: `nil` nghĩa là thiếu quyền Automation.

- [ ] **Step 1: `HotkeyConfig.swift`.**
  - Trong `struct HotkeyBinding`, thêm cạnh `defaultCurrentApp`:

```swift
    static let defaultFileDrop = HotkeyBinding(
        keyCode: 2, // D
        modifiersRaw: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
    )
```

  - Trong `enum Slot`, thêm `case fileDrop = "switch.hotkey.fileDrop"`.
  - Trong `seededDefault`, thêm `case .fileDrop: return .defaultFileDrop`.
  - Trong `private init()`, ngay sau khối `if !defaults.bool(forKey: seededKey) { … }`, thêm:

```swift
        // ⌃⌥D arrived after first-run seeding: give existing setups the default once.
        if !defaults.bool(forKey: "switch.hotkey.fileDropSeeded") {
            if load(.fileDrop) == nil { write(.defaultFileDrop, slot: .fileDrop) }
            defaults.set(true, forKey: "switch.hotkey.fileDropSeeded")
        }
```

- [ ] **Step 2: `HotkeyManager.swift`.** Thêm `var onFileDrop: (() -> Void)?` ngay dưới `var onStickyToggle: (() -> Void)?`. Trong `handle`, ngay sau khối `if let stickyBinding = … { … return nil }`, thêm:

```swift
            if let fileBinding = HotkeyConfig.shared[.fileDrop],
               fileBinding.matchesTrigger(keyCode: kc, flags: flags) {
                DispatchQueue.main.async { [weak self] in
                    self?.onFileDrop?()
                }
                return nil
            }
```

- [ ] **Step 3: Viết `FinderSelection.swift`**

```swift
import AppKit

/// The files selected in Finder, read over AppleScript (Automation → Finder, as the Trash
/// button already uses), off the main thread on one serial queue (NSAppleScript isn't
/// safe across threads).
@MainActor
enum FinderSelection {
    private static let queue = DispatchQueue(label: "win-tab.finder-selection", qos: .userInitiated)
    private static let script = """
    tell application "Finder"
        set out to ""
        repeat with f in (get selection as alias list)
            set out to out & POSIX path of f & linefeed
        end repeat
        return out
    end tell
    """

    /// Calls back with the selection (empty when Finder isn't in front or nothing is selected),
    /// or nil when win-tab isn't allowed to control Finder.
    static func read(_ done: @escaping @MainActor ([URL]?) -> Void) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
            done([])
            return
        }
        let source = script
        queue.async {
            var error: NSDictionary?
            let text = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
            let denied = (error?[NSAppleScript.errorNumber] as? Int) == -1743
            let urls = text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(denied ? nil : urls) } }
        }
    }
}
```

- [ ] **Step 4: `NotchController.swift`.** Thêm hằng `private static let filesHold: TimeInterval = 6` cạnh `popDuration`, và hàm sau, đặt sau `pop(_:)`:

```swift
    /// ⌃⌥D: the Files tab on the pointer's display, held open long enough to drag files in.
    func openFiles() {
        if !prefs.notchTabs.contains("shelf") { prefs.notchTabs.insert("shelf") }
        let mouse = NSEvent.mouseLocation
        let visible = islands.filter { !$0.steppedAside }
        guard let island = visible.first(where: { NSMouseInRect(mouse, $0.screenFrame, false) }) ?? visible.first else { return }
        island.holdUntil = Date().addingTimeInterval(Self.filesHold)
        expand(island, tab: .shelf)
    }
```

- [ ] **Step 5: `AppDelegate.swift`.** Ngay sau khối `hotkey.onStickyToggle = { … }`, thêm:

```swift
        hotkey.onFileDrop = { [weak self] in
            MainActor.assumeIsolated {
                FinderSelection.read { urls in
                    if let urls {
                        FileShelf.shared.add(urls)
                    } else {
                        FileShelf.shared.notice = "Allow win-tab to control Finder in Privacy & Security › Automation"
                    }
                }
                self?.notch?.openFiles()
            }
        }
```

- [ ] **Step 6: `SettingsView.swift`.** Sau dòng `hotkeyRow("Sticky toggle", …)` (hết lời gọi), thêm:

```swift
                        hotkeyRow("Files on the notch", rows: [("Primary", .fileDrop)],
                                  detail: "Opens the notch's Files tab; files selected in Finder are added.")
```

- [ ] **Step 7: Mục Settings → Notch → Files.** Trong `NotchSettingsTab.swift`, sau dòng `if prefs.notchTabs.contains("ports") { NotchPortsSettings() }`, thêm `if prefs.notchTabs.contains("shelf") { NotchFilesSettings() }`. Đặt struct này cạnh `NotchPortsSettings`:

```swift
/// Settings → Notch → Files.
private struct NotchFilesSettings: View {
    @AppStorage(FileJobQueue.qualityKey) private var quality = 0.8
    @AppStorage(FileJobQueue.replaceOriginalKey) private var replaceOriginal = false

    var body: some View {
        SettingsSection(title: "Files", subtitle: "Results are saved next to the original. ⌃⌥D opens the Files tab (change it in General → Hotkeys).") {
            SettingsCard {
                SettingsSlider(title: "Quality", value: "\(Int((quality * 100).rounded()))% · JPG, HEIC and AVIF; lower is smaller",
                               number: $quality, range: 0.5...0.95, step: 0.05)
                SettingsDivider()
                SettingsToggle(title: "Replace the original",
                               detail: "The original goes to the Trash and the result takes its place. Off: both are kept.",
                               isOn: $replaceOriginal)
            }
        }
    }
}
```

- [ ] **Step 8: Build app.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 9: Kiểm tra ⌃⌥D.** Cài bản build, rồi kiểm ba trường hợp, dùng phím giả lập từ probe có quyền:
  - Chọn 2 file trong Finder, nhấn ⌃⌥D: notch mở tab Files với đúng 2 file đó.
  - Nhấn ⌃⌥D khi app phía trước không phải Finder: notch mở tab Files, không thêm file.
  - ⌃D trong Terminal vẫn là EOF.
- [ ] **Step 10: Commit**

```bash
git add Sources/Switch
git commit -m "feat(files): ⌃⌥D opens the Files tab with Finder's selection; Files settings"
```

---

### Task 9: Đo lại, hồi quy, cài bản cuối

- [ ] **Step 1: Bài tự kiểm lõi.** Expected: `PASS 45 checks`.
- [ ] **Step 2: Build Debug và Release.** Expected: cả hai `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Hồi quy focus.** Cài bản Debug và chạy `swift tools/focus-test.swift`. Expected: chỉ còn lỗi Chrome 54769 (giới hạn đã biết) và các lỗi lẻ do Claude.app giành focus.
- [ ] **Step 4: Hồi quy Mission Control.** Dùng probe đo các lớp cửa sổ win-tab còn vẽ trong Mission Control. Expected: 0 cửa sổ.
- [ ] **Step 5: Đo tài nguyên.** Cài bản Release, để rảnh 30 phút. Đạt khi footprint ≤ 70 MB và CPU ≤ 0.18 s trong 60 s. Sau đó chạy một job nén video 1 phút: CPU của win-tab trong lúc chạy phải thấp (phần mã hoá chạy ở tiến trình hệ thống), và footprint trở về mức rảnh trong vòng 1 phút sau khi xong.
- [ ] **Step 6: Dọn bản build.** Gỡ đăng ký LaunchServices rồi chuyển `build/Build/Products/*/win-tab.app` vào Thùng rác. `mdfind "kMDItemCFBundleIdentifier == 'com.mn.wintab'"` chỉ được còn `/Applications/win-tab.app`.
