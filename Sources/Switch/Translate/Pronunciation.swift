import Foundation
import NaturalLanguage

/// IPA for English words from the dictionaries macOS ships: British from the Oxford Dictionary
/// of English (already IPA), American from the New Oxford American Dictionary (Oxford's own
/// respelling, turned into IPA here). Nothing is downloaded or bundled.
enum Pronunciation {
    enum Accent: String, CaseIterable, Identifiable {
        case us, uk
        var id: String { rawValue }
        var label: String { self == .us ? "US" : "UK" }
        var dictionaryName: String { self == .us ? "New Oxford American Dictionary" : "Oxford Dictionary of English" }
        var speechLanguage: String { self == .us ? "en-US" : "en-GB" }
    }

    struct Word: Identifiable, Equatable {
        let id: Int
        let text: String
        /// IPA (pinyin for Chinese); nil when there's none.
        let ipa: String?
    }

    /// Words of `text` with their IPA, in order. Runs the dictionary lookups on the caller's
    /// thread: call it off the main thread.
    static func words(in text: String, accent: Accent) -> [Word] {
        tokens(text).enumerated().map { i, word in Word(id: i, text: word, ipa: ipa(for: word, accent: accent)) }
    }

    /// Letters and apostrophes: "don't", "schedule".
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch == "'" || ch == "’" {
                current.append(ch == "’" ? "'" : ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Lookup

    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 500

    static func ipa(for word: String, accent: Accent) -> String? {
        let key = "\(accent.rawValue):\(word.lowercased())"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let found = lookup(word.lowercased(), accent: accent)
        lock.lock()
        cache[key] = found
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        lock.unlock()
        return found
    }

    /// A search for "meeting" also finds "meet", and "more" finds "many" first: the word's own entry
    /// wins, then a form an entry spells out ("have … has |haz|"), then a regular ending on the base
    /// word ("reschedule" + d). Nothing rather than the base word's sound.
    private static func lookup(_ word: String, accent: Accent) -> String? {
        guard let dict = DictionaryServices.dictionary(named: accent.dictionaryName) else { return nil }
        let entries = DictionaryServices.recordsHTML(in: dict, for: word)
        let ipa = { (raw: String) in accent == .us ? americanIPA(raw) : raw }
        if let own = entries.first(where: { title(of: $0) == word }), let raw = firstPhonetic(in: own) { return ipa(raw) }
        for html in entries { if let raw = inflectionPhonetic(word, in: html) { return ipa(raw) } }
        guard let base = entries.first, let lemma = title(of: base), let ending = regularEnding(word, lemma: lemma),
              let raw = firstPhonetic(in: base) else { return nil }
        return adding(ending, to: ipa(raw))
    }

    /// The entry's headword, lowercased, without syllable dots: `d:title="meet·ing"` → "meeting".
    static func title(of html: String) -> String? {
        guard let start = html.range(of: "d:title=\""),
              let end = html.range(of: "\"", range: start.upperBound..<html.endIndex) else { return nil }
        return html[start.upperBound..<end.lowerBound].replacingOccurrences(of: "·", with: "").lowercased()
    }

    /// The sound given right after an inflection in the entry: `<span class="inf">has </span> | haz |`.
    static func inflectionPhonetic(_ word: String, in html: String) -> String? {
        var from = html.startIndex
        while let inf = html.range(of: "class=\"inf\">\(word)", range: from..<html.endIndex) {
            from = inf.upperBound
            let rest = html[inf.upperBound...]
            guard rest.first == " " || rest.first == "<" else { continue }
            // Its own pronunciation comes before the next inflection, or it has none.
            guard let ph = rest.range(of: "class=\"ph") else { return nil }
            if let next = rest.range(of: "class=\"inf\""), next.lowerBound < ph.lowerBound { continue }
            return firstPhonetic(in: String(rest))
        }
        return nil
    }

    enum Ending: Equatable { case s, ed, ing }

    /// The regular ending that turns `lemma` into `word`: walks, studies, stopped, making; made → nil.
    static func regularEnding(_ word: String, lemma: String) -> Ending? {
        let doubled = lemma.last.map { lemma + String($0) } ?? lemma
        let stem = lemma.hasSuffix("e") || lemma.hasSuffix("y") ? String(lemma.dropLast()) : lemma
        if word == lemma + "s" || word == lemma + "es" || (lemma.hasSuffix("y") && word == stem + "ies") { return .s }
        if word == lemma + "ed" || word == doubled + "ed" || (lemma.hasSuffix("e") && word == lemma + "d")
            || (lemma.hasSuffix("y") && word == stem + "ied") { return .ed }
        if word == lemma + "ing" || word == doubled + "ing" || (lemma.hasSuffix("e") && word == stem + "ing") { return .ing }
        return nil
    }

    /// The ending's sound after the word's last sound: cats /s/, dogs /z/, boxes /ɪz/; watched /t/,
    /// wanted /ɪd/, played /d/.
    static func adding(_ ending: Ending, to ipa: String) -> String {
        let sibilant = ["s", "z", "ʃ", "ʒ", "tʃ", "dʒ"].contains { ipa.hasSuffix($0) }
        let voiceless = ["p", "t", "k", "f", "θ", "s", "ʃ", "tʃ"].contains { ipa.hasSuffix($0) }
        switch ending {
        case .s: return ipa + (sibilant ? "ɪz" : voiceless ? "s" : "z")
        case .ed: return ipa + (ipa.hasSuffix("t") || ipa.hasSuffix("d") ? "ɪd" : voiceless ? "t" : "d")
        case .ing: return ipa + "ɪŋ"
        }
    }

    /// Text of the first `<span class="ph…">…</span>` (inner tags dropped).
    static func firstPhonetic(in html: String) -> String? {
        guard let start = html.range(of: "class=\"ph") else { return nil }
        guard let open = html.range(of: ">", range: start.upperBound..<html.endIndex) else { return nil }
        var depth = 1
        var i = open.upperBound
        var text = ""
        while i < html.endIndex, depth > 0 {
            if html[i...].hasPrefix("<span") { depth += 1 }
            if html[i...].hasPrefix("</span") { depth -= 1; if depth == 0 { break } }
            if html[i] == "<" {
                i = html[i...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                continue
            }
            text.append(html[i])
            i = html.index(after: i)
        }
        let cleaned = text.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "|,")))
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - American respelling → IPA

    /// The New Oxford American Dictionary's respelling key, longest first so "o͞o" wins over "o".
    private static let respelling: [(String, String)] = [
        ("T\u{35F}H", "ð"), ("o\u{35E}o", "u"), ("o\u{35D}o", "ʊ"),
        ("CH", "tʃ"), ("SH", "ʃ"), ("ZH", "ʒ"), ("TH", "θ"), ("NG", "ŋ"), ("KH", "x"),
        ("oi", "ɔɪ"), ("ou", "aʊ"),
        ("ā", "eɪ"), ("ē", "i"), ("ī", "aɪ"), ("ō", "oʊ"), ("ô", "ɔ"), ("ä", "ɑ"), ("ə", "ə"),
        ("a", "æ"), ("e", "ɛ"), ("i", "ɪ"), ("o", "ɑ"), ("u", "ʊ"), ("j", "dʒ"), ("y", "j"), ("g", "ɡ"),
    ]

    /// "ˈskeˌjo͞ol" → "ˈskɛˌdʒul". Each piece of the respelling is turned into IPA exactly once.
    static func americanIPA(_ respelled: String) -> String {
        var out = ""
        var scalars = Substring(respelled).unicodeScalars[...]
        outer: while let first = scalars.first {
            for (from, to) in respelling where scalars.starts(with: from.unicodeScalars) {
                out += to
                scalars = scalars.dropFirst(from.unicodeScalars.count)
                continue outer
            }
            out.unicodeScalars.append(first)
            scalars = scalars.dropFirst()
        }
        return out
    }
}

/// Pinyin for Chinese, word by word: 明天 → míng tiān (the system's Mandarin transform).
enum Pinyin {
    static func words(in text: String) -> [Pronunciation.Word] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = text
        var out: [Pronunciation.Word] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            let latin = word.applyingTransform(.mandarinToLatin, reverse: false)
            out.append(Pronunciation.Word(id: out.count, text: word, ipa: latin == word ? nil : latin))
            return true
        }
        return out
    }
}

/// The system dictionaries through DictionaryServices' private calls (the public
/// DCSCopyTextDefinition only reads the user's first active dictionary, as plain text).
enum DictionaryServices {
    private typealias CopyAvailable = @convention(c) () -> Unmanaged<CFSet>?
    private typealias GetName = @convention(c) (AnyObject) -> Unmanaged<CFString>?
    private typealias CopyRecords = @convention(c) (AnyObject, CFString, CFIndex, CFIndex) -> Unmanaged<CFArray>?
    private typealias RecordCopyData = @convention(c) (AnyObject, CFIndex) -> Unmanaged<CFString>?

    private static let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices", RTLD_NOW)
    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var byName: [String: AnyObject]?

    static func dictionary(named name: String) -> AnyObject? {
        lock.lock(); defer { lock.unlock() }
        if byName == nil {
            var found: [String: AnyObject] = [:]
            if let available = symbol("DCSCopyAvailableDictionaries", CopyAvailable.self),
               let getName = symbol("DCSDictionaryGetName", GetName.self),
               let set = available()?.takeRetainedValue() as? Set<AnyHashable> {
                for item in set {
                    let dict = item as AnyObject
                    if let n = getName(dict)?.takeUnretainedValue() as String? { found[n] = dict }
                }
            }
            byName = found
        }
        return byName?[name]
    }

    /// The entries a search finds, in the dictionary's order (a handful at most).
    static func recordsHTML(in dictionary: AnyObject, for word: String, limit: Int = 6) -> [String] {
        guard let records = symbol("DCSCopyRecordsForSearchString", CopyRecords.self),
              let data = symbol("DCSRecordCopyData", RecordCopyData.self),
              let list = records(dictionary, word as CFString, 0, 0)?.takeRetainedValue() as? [AnyObject] else { return [] }
        return list.prefix(limit).compactMap { data($0, 0)?.takeRetainedValue() as String? }
    }
}
