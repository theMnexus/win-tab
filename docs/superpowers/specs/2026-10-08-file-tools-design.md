# Công cụ file trên notch + kiểm tra sức khoẻ app

Ngày: 2026-10-08 · Trạng thái: chờ duyệt · Phạm vi: phần 1 (lõi xử lý) và phần 2 (notch, ⌃⌥D, file đang chọn trong Finder)

## 1. Mục tiêu

- Thả file lên notch, hoặc nhấn ⌃⌥D, rồi chọn thao tác và nhận file kết quả kèm dung lượng trước/sau.
- Thao tác: đổi định dạng ảnh, nén, đổi kích thước, xoá metadata; nén và đổi định dạng video/âm thanh; nén, gộp và chuyển đổi PDF; zip/giải nén; đổi tên hàng loạt.
- App vẫn nhẹ:
  - Công cụ file không tốn CPU/RAM khi không dùng.
  - RAM lúc rảnh trở về ≤ 70 MB (hiện 132 MB, đỉnh 302 MB).
  - CPU lúc rảnh ≤ 0.3% khi người dùng không dùng máy.

Ngoài phạm vi spec này (mỗi mục sẽ có spec riêng, dùng lại lõi ở mục 3):
- Quick Actions khi chuột phải trong Finder.
- Tự động tối ưu thư mục.
- Cửa sổ "File Tools" riêng.

## 2. Ràng buộc đã chốt

- Chỉ dùng framework của macOS: ImageIO, AVFoundation, PDFKit, QuickLookThumbnailing, và `/usr/bin/ditto`. Không thêm thư viện ngoài.
- Không xuất WebP, vì ImageIO trên macOS 27.0.1 chỉ đọc được WebP. Xuất AVIF thay thế.
- Không bao giờ ghi đè file gốc. Tuỳ chọn "Thay file gốc" mặc định tắt; khi bật thì bản cũ vào Thùng rác.
- Không gửi file ra mạng.
- Phím tắt mặc định ⌃⌥D, đổi được trong Settings. Không dùng ⌃D vì trùng EOF của Terminal và phím xoá phải trong ô nhập chữ.

## 3. Lõi xử lý: `Sources/Switch/FileTools/`

Lõi không import SwiftUI/AppKit UI, để chạy được độc lập trong bài tự kiểm tra.

| File | Trách nhiệm | Dựa trên |
|---|---|---|
| `FileOperation.swift` | Kiểu dữ liệu: `FileOperation` (thao tác + tuỳ chọn), `FileKind` (image, video, audio, pdf, archive, other) phân loại theo UTType, `JobResult` (file vào, file ra, dung lượng trước/sau, lỗi) | UniformTypeIdentifiers |
| `OutputNaming.swift` | Tên file kết quả cạnh file gốc: đổi đuôi, hoặc thêm hậu tố ` (compressed)`, ` (1920px)`…; trùng tên thì thêm ` 2`, ` 3` | Foundation |
| `ImageTool.swift` | Đổi sang JPEG/PNG/HEIC/AVIF/TIFF/GIF/PDF; nén theo chất lượng (mặc định 0.8); resize theo cạnh dài 3840/2560/1920/1280 px, không phóng to; xoá metadata (GPS, EXIF, TIFF), xoay đúng hướng trước khi bỏ orientation | ImageIO: `CGImageSourceCreateThumbnailAtIndex` với `kCGImageSourceThumbnailMaxPixelSize`, `CGImageDestination` |
| `MediaTool.swift` | Nén video: HEVC 1080p (mặc định), H.264 1080p, H.264 720p; MOV↔MP4 (passthrough nếu được); tách âm thanh → M4A; audio → M4A; báo tiến độ 0…1 | `AVAssetExportSession` |
| `PDFTool.swift` | Nén PDF (ảnh hạ chất lượng cho màn hình); gộp nhiều PDF theo thứ tự chọn; ảnh → 1 PDF; PDF → PNG 144 dpi từng trang | PDFKit: `PDFDocument.write(to:withOptions:)` với `.saveImagesAsJPEGOption`, `.optimizeImagesForScreenOption` |
| `ArchiveTool.swift` | Zip nhiều file → `Archive.zip` cạnh file đầu tiên; giải nén `.zip`; đổi tên hàng loạt theo mẫu (tiền tố, số thứ tự, thay chữ, đổi đuôi), có xem trước và hoàn tác lần đổi gần nhất | `/usr/bin/ditto -c -k --sequesterRsrc --keepParent`, `ditto -x -k`, `FileManager.moveItem` |
| `FileJobQueue.swift` | `@MainActor ObservableObject`: danh sách job, trạng thái (chờ/chạy/xong/lỗi/huỷ), tiến độ, huỷ. Chạy trên `OperationQueue` QoS utility: ảnh tối đa 2 cùng lúc, video/PDF 1 lúc, Energy Saver bật thì 1 lúc. Chỉ tạo khi có job đầu tiên | Foundation |

Quy tắc chung cho mọi thao tác:
- Ghi ra file tạm `.<tên>.partial` trong cùng thư mục, xong mới đổi tên. Lỗi hoặc huỷ thì xoá file tạm.
- Với thao tác nén: nếu kết quả không nhỏ hơn bản gốc thì xoá kết quả và báo "Đã tối ưu sẵn, giữ bản gốc".
- Mỗi file chạy trong `autoreleasepool`. Ảnh không bao giờ được giải mã ở cỡ lớn hơn cỡ đích.
- Lỗi được báo bằng lời cho từng file: không đọc được, không đủ quyền, hết dung lượng đĩa, video có DRM, định dạng không hỗ trợ. File khác vẫn chạy tiếp.

## 4. Giao diện: tab Shelf đổi thành Files

- Ô file có ảnh xem trước (QuickLook, cỡ 2× ô, cache tối đa 50) và nút chọn. Chọn được nhiều file; có "Chọn tất cả".
- Thanh thao tác chỉ hiện những thao tác hợp với các file đang chọn:
  - Ảnh: Convert ▾ (JPG, PNG, HEIC, AVIF, TIFF, PDF), Compress, Resize ▾, Strip metadata.
  - Video: Compress ▾ (HEVC 1080p, H.264 1080p, H.264 720p), Convert ▾ (MP4, MOV), Audio only.
  - Audio: Convert → M4A.
  - PDF: Compress, Merge (từ 2 file trở lên), To images.
  - Mọi loại: Zip, Rename…; file `.zip` có thêm Unzip; ảnh có thêm Images → PDF.
- Khi có job, các dòng job hiện bên dưới, gồm tên, thanh tiến độ và nút huỷ. Xong thì hiện "2.4 MB → 640 KB (−73%)". Bấm để mở trong Finder; kéo ra được như file thường.
- Rename mở một dòng nhập mẫu, có xem trước tên mới, nút Áp dụng và nút Hoàn tác.
- Tất cả phải vừa khung nội dung notch (580 × 158 pt ở cỡ Regular). Khi có nhiều job, danh sách job cuộn được.
- Settings → Notch → Files gồm:
  - Thay file gốc (tắt). File kết quả luôn nằm cạnh file gốc.
  - Chất lượng JPEG/HEIC mặc định.
  - Phím tắt ⌃⌥D.

## 5. Phím tắt ⌃⌥D và file đang chọn trong Finder

- Thêm một slot phím tắt vào `HotkeyConfig`/`HotkeyManager`, dùng event tap có sẵn. Mặc định ⌃⌥D. Kiểm tra trùng với các phím tắt hiện có.
- Nhấn phím: `NotchController` mở island trên màn hình có con trỏ, ở tab Files, với vùng "Drop files here" nổi bật.
- Nếu app phía trước là Finder và đang có file được chọn: đọc lựa chọn bằng AppleScript `tell application "Finder" to get selection as alias list`, chạy ở luồng nền, rồi thêm vào Files.
  - Nếu thiếu quyền Automation (lỗi −1743): hiện dòng gợi ý có nút Open, mở Privacy & Security › Automation.

## 6. Kiểm tra sức khoẻ app (làm trước phần tính năng)

1. Đo trạng thái hiện tại:
   - `footprint` lúc rảnh;
   - `leaks <pid>`;
   - `heap <pid> --showSizes`, lọc các khối lớn;
   - CPU bằng hiệu `ps -o time=` trong 60 s khi người dùng không dùng máy, kèm `sample` để biết hàm nào chạy.
2. Tìm thứ phình ra, ví dụ artwork nhạc, feed thông báo, clipboard, ảnh xem trước, tab System/Ports, cache icon. Sửa đúng nguyên nhân, không giới hạn mù.
3. Mục tiêu:
   - RAM lúc rảnh ≤ 70 MB sau 1 giờ chạy, không tăng dần;
   - CPU lúc rảnh ≤ 0.3%.
   - Báo số trước/sau có đơn vị. Loại các lần đo trùng lúc người dùng đang thao tác.

## 7. Kiểm thử

- `tools/filetools-check.swift`: biên dịch cùng `Sources/Switch/FileTools/*.swift`. Bài kiểm tra:
  - Tự tạo dữ liệu mẫu: ảnh PNG 4000 × 3000 có GPS, video 2 s bằng `AVAssetWriter`, PDF 3 trang có ảnh, thư mục nhỏ.
  - Chạy mọi thao tác, rồi assert: file ra tồn tại; UTType đúng; thao tác nén cho file nhỏ hơn; resize cho cạnh dài đúng; ảnh sau khi xoá metadata không còn GPS; file gốc giữ nguyên checksum; tên trùng được thêm số; huỷ giữa chừng không để lại file `.partial`.
  - In thời gian và RAM đỉnh của từng thao tác.
- Giao diện:
  - Chụp tab Files ở 4 trạng thái: trống, đã chọn, đang chạy, có kết quả.
  - Thử ⌃⌥D bằng phím giả lập, có và không có file đang chọn trong Finder.
- Hồi quy: `tools/focus-test.swift`, phép đo ẩn notch/Dock trong Mission Control, và build cả Debug lẫn Release.

## 8. Thứ tự làm

1. Kiểm tra sức khoẻ (mục 6).
2. Lõi + bài tự kiểm tra (mục 3, mục 7).
3. Tab Files (mục 4).
4. ⌃⌥D + lựa chọn trong Finder (mục 5).
5. Settings.
6. Đo lại tài nguyên, cài bản mới.
