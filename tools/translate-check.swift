// Self-check for the Translate pieces that need no UI. Run:
//   swiftc -parse-as-library tools/translate-check.swift Sources/Switch/Translate/{Pronunciation,SpeechScore,OnlineTranslator,Languages}.swift -o /tmp/translate-check && /tmp/translate-check
import Foundation

@main
struct TranslateCheck {
    static var passed = 0
    static func check(_ ok: Bool, _ what: String, line: UInt = #line) {
        guard ok else { print("FAIL \(what) (line \(line))"); exit(1) }
        passed += 1
    }

    static func main() {
        // American respelling → IPA.
        let cases = [("ˈskeˌjo͞ol", "ˈskɛˌdʒul"), ("təˈmādō", "təˈmeɪdoʊ"), ("THro͞o", "θru"), ("THôt", "θɔt"), ("CHərCH", "tʃərtʃ"),
                     ("prəˌnən(t)sēˈāSHən", "prəˌnən(t)siˈeɪʃən"), ("T͟Hə", "ðə"), ("bo͝ok", "bʊk"), ("ˈsiNGiNG", "ˈsɪŋɪŋ")]
        for (respelled, ipa) in cases {
            let got = Pronunciation.americanIPA(respelled)
            check(got == ipa, "\(respelled) → \(ipa), got \(got)")
        }
        check(Pronunciation.tokens("Don’t stop, it's 5 o'clock!") == ["Don't", "stop", "it's", "o'clock"], "tokens")
        check(Pronunciation.firstPhonetic(in: #"<span class="ph">ˈʃɛdjuːl</span>, <span class="ph">x</span>"#) == "ˈʃɛdjuːl", "first phonetic span")
        check(Pronunciation.firstPhonetic(in: #"<span class="ph t_x">|<span class="s">ˈ</span>skeˌjo͞ol|</span>"#) == "ˈskeˌjo͞ol", "nested span")

        // Dictionary lookups on this Mac.
        for (word, us, uk) in [("schedule", "ˈskɛˌdʒul", "ˈʃɛdjuːl"), ("tomato", "təˈmeɪdoʊ", "təˈmɑːtəʊ"), ("through", "θru", "θruː")] {
            let gotUS = Pronunciation.ipa(for: word, accent: .us), gotUK = Pronunciation.ipa(for: word, accent: .uk)
            print("  \(word): US \(gotUS ?? "nil") · UK \(gotUK ?? "nil")")
            check(gotUS == us && gotUK == uk, "dictionary IPA for \(word)")
        }
        check(Pronunciation.ipa(for: "qwzxv", accent: .us) == nil, "unknown word has no IPA")

        // Inflected words: their own entry, the form an entry spells out, or a regular ending —
        // never the base word's sound ("meeting" is not "meet", "more" is not "many").
        for (word, us, uk) in [("meeting", "ˈmidɪŋ", "ˈmiːtɪŋ"), ("has", "hæz", "haz"), ("been", "bɪn", "biːn"),
                               ("more", "mɔr", "mɔː"), ("rescheduled", "riˈskɛdʒəld", "ˌriːˈʃɛdjuːld")] {
            let gotUS = Pronunciation.ipa(for: word, accent: .us), gotUK = Pronunciation.ipa(for: word, accent: .uk)
            print("  \(word): US \(gotUS ?? "nil") · UK \(gotUK ?? "nil")")
            check(gotUS == us && gotUK == uk, "inflected IPA for \(word)")
        }
        check(Pronunciation.title(of: #"<d:entry id="x" d:title="meet·ing" class="entry">"#) == "meeting", "entry title")
        check(Pronunciation.inflectionPhonetic("has", in: #"<span class="inf">has </span><span class="prx"> | <span class="ph t_respell">haz</span> |</span><span class="inf">having </span>"#) == "haz", "inflection phonetic")
        check(Pronunciation.inflectionPhonetic("had", in: #"<span class="inf">has </span><span class="prx"> | <span class="ph">haz</span></span>"#) == nil, "absent inflection")
        let endings: [(String, String, Pronunciation.Ending?)] = [("rescheduled", "reschedule", .ed), ("stopped", "stop", .ed), ("making", "make", .ing),
                                                                ("studies", "study", .s), ("boxes", "box", .s), ("walks", "walk", .s), ("more", "many", nil)]
        for (word, lemma, ending) in endings { check(Pronunciation.regularEnding(word, lemma: lemma) == ending, "ending of \(word)") }
        let added: [(String, Pronunciation.Ending, String)] = [("kæt", .s, "kæts"), ("dɔɡ", .s, "dɔɡz"), ("bɑks", .s, "bɑksɪz"), ("wɑtʃ", .ed, "wɑtʃt"),
                                                              ("wɑnt", .ed, "wɑntɪd"), ("pleɪ", .ed, "pleɪd"), ("sɪŋ", .ing, "sɪŋɪŋ"), ("ˈstədi", .s, "ˈstədiz")]
        for (ipa, ending, want) in added { check(Pronunciation.adding(ending, to: ipa) == want, "\(ipa) + \(ending) → \(want)") }

        // Pinyin: Chinese split into words, each with tone-marked pinyin; punctuation left out.
        let pinyin = Pinyin.words(in: "我们明天开会。")
        print("  pinyin: " + pinyin.map { "\($0.text) \($0.ipa ?? "nil")" }.joined(separator: " · "))
        check(pinyin.map(\.text) == ["我们", "明天", "开会"], "Chinese words")
        check(pinyin.map(\.ipa) == ["wǒ men", "míng tiān", "kāi huì"], "pinyin with tones")
        check(Pinyin.words(in: "用 iPhone 拍照").first { $0.text == "iPhone" }?.ipa == nil, "Latin word has no pinyin")

        // Languages: detection held to English, Chinese and Vietnamese.
        for (text, want) in [("https://drive.google.com/drive/folders/1Yry?usp=sharing", "en"), ("schedule", "en"), ("你好，世界", "zh-Hans"),
                             ("Xin chào", "vi"), ("The meeting has been rescheduled.", "en")] {
            check(Languages.detect(text) == want, "detect \(text) → \(want), got \(Languages.detect(text) ?? "nil")")
        }
        check(Languages.normalize("zh-CN") == "zh-Hans" && Languages.normalize("en-US") == "en" && Languages.normalize("fr") == "fr", "normalize")
        check(Languages.google("zh-Hans") == "zh-CN" && Languages.google("vi") == "vi", "Google codes")
        check(Languages.speech("zh-Hans") == "zh-CN" && Languages.speech("vi") == "vi-VN" && Languages.speech("en-GB") == "en-GB", "speech codes")

        // Speaking score.
        let full = SpeechScore.score(target: "I would like a cup of coffee", heard: "i would like a cup of coffee")
        check(full.percent == 100 && full.words.allSatisfy(\.said), "all words said")
        let missed = SpeechScore.score(target: "I would like a cup of coffee", heard: "I like a cup of tea")
        check(missed.words.map(\.said) == [true, false, true, true, true, true, false] && missed.percent == 71, "missed words marked: \(missed.percent)")
        check(SpeechScore.score(target: "", heard: "x").percent == 0, "empty target")

        // Google answer parsing.
        let json = #"[[["Xin chào ","Hello ",null,null,10],["thế giới","world",null,null,10]],null,"en"]"#
        let parsed = OnlineTranslator.parse(Data(json.utf8))
        check(parsed?.text == "Xin chào thế giới" && parsed?.detected == "en", "parse Google answer")
        check(OnlineTranslator.parse(Data("<html>".utf8)) == nil, "bad answer is nil")
        print("PASS \(passed) checks")
    }
}
