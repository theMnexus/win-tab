import Foundation
import Translation

/// What the Translate tab shows: the text, the languages, the translation and its IPA. On-device
/// translation needs a SwiftUI `.translationTask`, so this only posts `deviceRequest` and the
/// tab's `DeviceTranslationRunner` answers it; Google (Settings → Translate → Online) runs here.
@MainActor
final class TranslateModel: ObservableObject {
    static let shared = TranslateModel()
    static let onlineKey = "switch.translate.online"
    static let targetKey = "switch.translate.target"
    static let accentKey = "switch.translate.accent"
    static let speedKey = "switch.translate.speed"

    enum Engine: Equatable {
        case device, google
        var label: String { self == .device ? "On this Mac" : "Google" }
    }

    enum Status: Equatable {
        case idle, translating, failed(String)
    }

    struct DeviceRequest: Equatable {
        let id = UUID()
        let text: String
        let from: String?
        let to: String
    }

    @Published var source = ""
    /// nil: detected from the text.
    @Published var from: String?
    @Published var to: String { didSet { UserDefaults.standard.set(to, forKey: Self.targetKey) } }
    @Published private(set) var detected: String?
    @Published private(set) var translation = ""
    @Published private(set) var engine: Engine = .device
    @Published private(set) var status: Status = .idle
    @Published var accent: Pronunciation.Accent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: Self.accentKey); refreshWords() }
    }
    @Published var speed: Double { didSet { UserDefaults.standard.set(speed, forKey: Self.speedKey) } }
    /// IPA for the English side, or pinyin for the Chinese side (see `pronouncedLanguage`).
    @Published private(set) var words: [Pronunciation.Word] = []
    /// Which side the Pronunciation card shows when both have one (English and Chinese).
    @Published var pronounce = "en" { didSet { refreshWords() } }
    @Published private(set) var deviceRequest: DeviceRequest?
    private(set) var answeredRequest: UUID?

    private init() {
        let d = UserDefaults.standard
        // A target saved before the list was cut to three falls back to Vietnamese.
        to = d.string(forKey: Self.targetKey).flatMap { Languages.all.contains($0) ? $0 : nil } ?? "vi"
        accent = Pronunciation.Accent(rawValue: d.string(forKey: Self.accentKey) ?? "") ?? .us
        speed = d.object(forKey: Self.speedKey) as? Double ?? 1
    }

    var online: Bool { UserDefaults.standard.bool(forKey: Self.onlineKey) }
    var sourceLanguage: String? { from ?? detected }

    /// The English side, for IPA, reading aloud and practice.
    var englishText: String? {
        if Languages.base(sourceLanguage) == "en" { return source }
        if Languages.base(to) == "en", !translation.isEmpty { return translation }
        return nil
    }

    /// The Chinese side: the text, or the translation when translating into Chinese.
    var chineseText: String? {
        if Languages.base(sourceLanguage) == "zh" { return source }
        if Languages.base(to) == "zh", !translation.isEmpty { return translation }
        return nil
    }

    /// Languages the Pronunciation card can show for this pair ("en", "zh-Hans").
    var pronounceable: [String] { [englishText.map { _ in "en" }, chineseText.map { _ in "zh-Hans" }].compactMap { $0 } }
    var pronouncedLanguage: String? { pronounceable.contains(pronounce) ? pronounce : pronounceable.first }
    var pronouncedText: String? {
        switch pronouncedLanguage {
        case "en": return englishText
        case "zh-Hans": return chineseText
        default: return nil
        }
    }

    func translate(_ text: String) {
        source = text
        from = nil
        run()
    }

    /// Translates `source` again (after an edit or a language change).
    func run() {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        detected = Languages.detect(text)
        // The same language on both sides: Vietnamese goes to English, anything else to Vietnamese.
        if let s = sourceLanguage, Languages.base(s) == Languages.base(to) { to = Languages.base(s) == "vi" ? "en" : "vi" }
        status = .translating
        translation = ""
        words = []
        let target = to, src = sourceLanguage
        if online {
            Task {
                let answer = await OnlineTranslator.translate(text, from: self.from.map(Languages.google), to: Languages.google(target))
                guard self.source.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                if let answer {
                    self.finish(answer.text, engine: .google, detected: answer.detected)
                } else {
                    self.requestDevice(text, from: src, to: target)
                }
            }
        } else {
            requestDevice(text, from: src, to: target)
        }
    }

    private func requestDevice(_ text: String, from: String?, to: String) {
        engine = .device
        deviceRequest = DeviceRequest(text: text, from: from, to: to)
    }

    /// The Translate tab's runner, with a session for `request`.
    @available(macOS 15.0, *)
    func runDevice(_ session: TranslationSession, request: DeviceRequest) async {
        do {
            let response = try await session.translate(request.text)
            guard deviceRequest == request else { return }
            answeredRequest = request.id
            finish(response.targetText, engine: .device, detected: response.sourceLanguage.minimalIdentifier)
        } catch {
            guard deviceRequest == request else { return }
            answeredRequest = request.id
            NSLog("win-tab: on-device translation failed: \(error)")
            status = .failed("Couldn't translate on this Mac. Download \(Languages.name(request.from ?? "en")) and \(Languages.name(request.to)) when macOS asks, or turn on Online in Settings → Notch → Translate.")
        }
    }

    private func finish(_ text: String, engine: Engine, detected: String?) {
        translation = text
        self.engine = engine
        if from == nil, let detected, !detected.isEmpty { self.detected = Languages.normalize(detected) }
        status = .idle
        refreshWords()
        PhraseBook.shared.record(source: source, translation: text, from: sourceLanguage ?? "auto", to: to)
    }

    /// Opens an entry from the phrase book without translating again.
    func show(_ entry: PhraseBook.Entry) {
        source = entry.source
        from = entry.from == "auto" ? nil : entry.from
        detected = entry.from == "auto" ? Languages.detect(entry.source) : entry.from
        to = entry.to
        translation = entry.translation
        status = .idle
        refreshWords()
    }

    func swapLanguages() {
        guard let s = sourceLanguage else { return }
        let old = to
        if !translation.isEmpty { source = translation }
        to = s
        from = old
        run()
    }

    func refreshWords() {
        guard let language = pronouncedLanguage, let text = pronouncedText else { words = []; return }
        words = []
        let accent = accent
        Task.detached(priority: .userInitiated) {
            let found = language == "en" ? Pronunciation.words(in: text, accent: accent) : Pinyin.words(in: text)
            await MainActor.run {
                if self.pronouncedText == text && self.pronouncedLanguage == language && self.accent == accent { self.words = found }
            }
        }
    }

}
