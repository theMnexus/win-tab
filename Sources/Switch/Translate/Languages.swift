import Foundation
import NaturalLanguage

/// The Translate tab's languages: English, Chinese (Simplified) and Vietnamese.
enum Languages {
    static let all = ["en", "zh-Hans", "vi"]

    /// One of `all`. Detection is held to the three, so a URL or a single word ("schedule") never
    /// comes out as Polish or Norwegian. nil for text with no letters.
    static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .simplifiedChinese, .vietnamese]
        recognizer.processString(text)
        return recognizer.dominantLanguage.map { normalize($0.rawValue) }
    }

    /// "zh-CN", "zh" or "en-US" as written in `all`; other codes unchanged.
    static func normalize(_ code: String) -> String {
        switch base(code) {
        case "en": return "en"
        case "zh": return "zh-Hans"
        case "vi": return "vi"
        default: return code
        }
    }

    static func base(_ code: String?) -> String { String((code ?? "").split(separator: "-").first ?? "") }

    /// Google's code: it takes zh-CN, not zh-Hans.
    static func google(_ code: String) -> String { base(code) == "zh" ? "zh-CN" : code }

    /// The code speech voices use (zh-CN, vi-VN).
    static func speech(_ code: String) -> String {
        switch base(code) {
        case "zh": return "zh-CN"
        case "vi": return "vi-VN"
        default: return code
        }
    }

    static func name(_ code: String) -> String { Locale.current.localizedString(forIdentifier: code) ?? code }

    /// Short names for menus and card headers.
    static func label(_ code: String) -> String {
        switch base(code) {
        case "en": return "English"
        case "zh": return "Chinese"
        case "vi": return "Vietnamese"
        default: return name(code)
        }
    }
}
