# Dịch và luyện phát âm trên notch

Ngày: 2026-10-08 · Trạng thái: đã duyệt (phần 1 duyệt trong chat; phần còn lại người dùng yêu cầu làm luôn)

## 1. Mục tiêu

- Bôi đen chữ ở bất kỳ app nào, hoặc copy vào clipboard, rồi nhấn **⌃⌥C**. Notch mở tab **Translate** với bản dịch.
- Mặc định dịch sang tiếng Việt. Nếu câu gốc là tiếng Việt thì dịch sang tiếng Anh. Đổi được sang 47 ngôn ngữ.
- Luyện tiếng Anh:
  - IPA từng từ, chọn được giọng Mỹ (US) hoặc Anh (UK).
  - Nghe đọc mẫu ở tốc độ 1× / 0.75× / 0.5×, có tô sáng từng từ khi đọc; bấm vào một từ để nghe riêng từ đó.
  - Luyện nói: thu micro, nhận dạng giọng nói ngay trên máy, tô xanh/đỏ từng từ và cho điểm %.
- Có sổ từ: lịch sử 200 lần dịch gần nhất và các câu/từ đã lưu, ghi trên máy.
- Khi không dùng, tính năng này không tốn CPU/RAM. Chỉ chạy lúc tab mở hoặc lúc nhấn phím.

## 2. Ràng buộc đã chốt

- Phím tắt **⌃⌥C** (keyCode 8, Control + Option). Không dùng ⌃C vì đó là phím dừng chương trình trong terminal.
- Cách **C (lai)**:
  - Mặc định dịch trên máy bằng Apple Translation.
  - Công tắc "Dịch online (Google)", mặc định tắt.
  - Google lỗi hoặc hết thời gian chờ (8 s) thì tự quay về dịch trên máy.
- IPA:
  - UK lấy từ *Oxford Dictionary of English* có sẵn trong macOS.
  - US lấy từ *New Oxford American Dictionary*, rồi đổi cách ghi âm kiểu Mỹ của từ điển này sang IPA bằng bảng ánh xạ cố định. Không tải hay gói thêm từ điển nào.
- Đọc mẫu bằng giọng có sẵn của macOS (`AVSpeechSynthesizer`), ưu tiên giọng chất lượng cao nếu máy đã tải.
- Nhận dạng giọng nói bằng `SFSpeechRecognizer`, chạy hoàn toàn trên máy (`requiresOnDeviceRecognition`).
- Lấy chữ đang bôi đen:
  - Ưu tiên đọc `AXSelectedText` của ô đang focus.
  - Không đọc được thì giả lập ⌘C, đọc clipboard, trả clipboard về như cũ, và không ghi lần copy đó vào lịch sử Clipboard.
  - Không có chữ bôi đen thì dùng chữ đang có trong clipboard.
- Dữ liệu sổ từ ở `~/Library/Application Support/win-tab/phrasebook.json`, dạng `[{"id": "…", "date": "2026-10-08T14:20:00Z", "source": "hello", "translation": "xin chào", "from": "en", "to": "vi", "saved": false}]`.

## 3. Các khối: `Sources/Switch/Translate/`

| File | Trách nhiệm |
|---|---|
| `TranslateModel.swift` | `@MainActor ObservableObject`: câu gốc, ngôn ngữ nguồn (Auto) và đích, kết quả, trạng thái (đang dịch / cần tải ngôn ngữ / lỗi), nguồn dịch (trên máy / Google). Nhận diện ngôn ngữ bằng `NLLanguageRecognizer`. |
| `OnlineTranslator.swift` | Gọi `translate.googleapis.com/translate_a/single?client=gtx` qua HTTPS, đọc JSON, timeout 8 s. |
| `Pronunciation.swift` | Tách từ, tra IPA UK/US qua DictionaryServices, chuyển cách ghi âm kiểu Mỹ sang IPA, nhớ 500 từ gần nhất. |
| `SpeechCoach.swift` | Đọc mẫu (giọng, tốc độ, từ đang đọc). Luyện nói: thu âm, nhận dạng, so khớp từng từ, cho điểm. |
| `PhraseBook.swift` | Lịch sử và mục đã lưu, ghi JSON ở luồng nền, sau 1 s không có thay đổi mới. |
| `SelectionReader.swift` | Lấy chữ đang bôi đen theo thứ tự ở mục 2. |

Giao diện: `Sources/Switch/Notch/NotchTranslateView.swift`, tab `NotchTab.translate`, cao thêm 120 pt (kéo được bằng thanh dưới đáy, dùng chung `NotchTabHeights`).

## 4. Lỗi và giới hạn

- Gói ngôn ngữ chưa tải: hiện nút "Download <ngôn ngữ>" để gọi `prepareTranslation()`, và gợi ý bật dịch online.
- Chưa cấp quyền micro hoặc nhận dạng giọng nói: hiện dòng hướng dẫn có nút mở đúng trang trong System Settings.
- Từ không có trong từ điển: không hiện IPA cho từ đó, các từ khác vẫn hiện.
- Câu dài hơn 5.000 ký tự thì cắt bớt và báo.

## 5. Kiểm thử

- `tools/translate-check.swift` cho phần không cần giao diện:
  - Bảng đổi cách ghi âm sang IPA: *schedule*, *tomato*, *through*, *thought*, *church* ra đúng IPA.
  - Hàm chấm điểm luyện nói: khớp hết thì 100%; thiếu một từ thì từ đó bị đánh dấu.
  - Tra từ điển UK/US cho 5 từ.
- Trên máy:
  - Bôi đen một câu tiếng Anh trong Notes → ⌃⌥C → có bản dịch, IPA, nghe được.
  - Đổi ngôn ngữ đích; dịch tiếng Việt → tiếng Anh.
  - Lưu vào sổ từ; mở lại thấy mục đã lưu.
