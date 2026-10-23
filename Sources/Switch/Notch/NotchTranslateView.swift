import AppKit
import SwiftUI
import Translation

/// Answers `TranslateModel.deviceRequest` with Apple's on-device translation (macOS 15+).
@available(macOS 15.0, *)
struct DeviceTranslationRunner: View {
    @ObservedObject var model: TranslateModel
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(config) { session in
                guard let request = model.deviceRequest else { return }
                await model.runDevice(session, request: request)
            }
            .onChange(of: model.deviceRequest) { _, request in apply(request) }
            .onAppear {
                if let request = model.deviceRequest, request.id != model.answeredRequest { apply(request) }
            }
    }

    private func apply(_ request: TranslateModel.DeviceRequest?) {
        guard let request else { return }
        let source = request.from.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: request.to)
        if config?.source == source && config?.target == target {
            config?.invalidate()
        } else {
            config = TranslationSession.Configuration(source: source, target: target)
        }
    }
}

/// The notch's Translate tab, in cards: the text and its translation side by side (each with its
/// language, listen and copy), pronunciation under them (IPA word by word, accent, speed,
/// practice); the phrase book on its own page.
struct NotchTranslateView: View {
    @ObservedObject var state: NotchState
    @ObservedObject private var model = TranslateModel.shared
    @ObservedObject private var coach = SpeechCoach.shared
    @ObservedObject private var book = PhraseBook.shared
    @ObservedObject private var heights = NotchTabHeights.shared
    @State private var showingBook = false
    @State private var editing = false
    @State private var draft = ""
    @State private var copied: String?
    /// What Listen is reading, so only that card shows Stop.
    @State private var reading: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topBar
            if showingBook {
                bookCard
            } else if model.source.isEmpty && !editing {
                emptyCard
            } else {
                translator
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if #available(macOS 15.0, *) { DeviceTranslationRunner(model: model) }
        }
        .overlay(alignment: .bottom) {
            NotchResizeHandle(state: state, extra: $heights.translate, maxExtra: NotchTabHeights.maxExtra,
                              defaultExtra: NotchTabHeights.translateDefault).offset(y: 12)
        }
        .onAppear { book.load() }
        .onDisappear {
            coach.stopSpeaking()
            coach.stopPractice(score: false)
            endEditing()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            NotchSegmented(options: [(false, "Translate"), (true, "Phrase book")], selection: showingBook) { showingBook = $0 }
            Spacer(minLength: 4)
            if !showingBook && !model.translation.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(model.engine == .device ? Color.green : .blue).frame(width: 5, height: 5)
                    Text(model.engine.label)
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .help(model.engine == .device ? "Translated on this Mac" : "Translated by Google (Settings → Notch → Translate → Online)")
            }
        }
        .frame(height: 22)
    }

    // MARK: - Translator

    private var translator: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                sourceCard
                translationCard
            }
            .overlay(alignment: .top) { swapButton.offset(y: 6) }
            .frame(maxHeight: .infinity)
            if let language = model.pronouncedLanguage { pronunciationCard(language) }
        }
    }

    /// Sits over the gap between the two cards, cut out of them.
    private var swapButton: some View {
        Button { model.swapLanguages() } label: {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color(white: 0.17)))
                .overlay(Circle().strokeBorder(Color.black, lineWidth: 2.5))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(model.sourceLanguage == nil || editing)
        .help("Swap languages")
    }

    private var sourceCard: some View {
        NotchCard(grows: true) {
            HStack(spacing: 2) {
                languageMenu(source: true)
                Spacer(minLength: 4)
                listenChip(model.source, language: model.sourceLanguage)
                copyChip(model.source, help: "Copy the text")
            }
            .frame(height: 22)
            .padding(.trailing, 12)
            if editing {
                editor
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(model.source).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture { startEditing() }
                .help("Click to edit")
            }
        }
    }

    private var translationCard: some View {
        let saved = book.isSaved(source: model.source, to: model.to)
        return NotchCard(grows: true) {
            HStack(spacing: 2) {
                languageMenu(source: false)
                Spacer(minLength: 4)
                Group {
                    listenChip(model.translation, language: model.to)
                    NotchChip(symbol: saved ? "star.fill" : "star", tint: saved ? .yellow : nil, quiet: true,
                              help: saved ? "Remove from the phrase book" : "Save to the phrase book") {
                        book.toggleSaved(source: model.source, to: model.to)
                    }
                    copyChip(model.translation, help: "Copy the translation")
                }
                .disabled(model.translation.isEmpty)
            }
            .frame(height: 22)
            .padding(.leading, 12)
            translationBody
        }
    }

    @ViewBuilder private var translationBody: some View {
        switch model.status {
        case .translating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Translating…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
        case .failed(let message):
            ScrollView(.vertical, showsIndicators: false) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .idle:
            ScrollView(.vertical, showsIndicators: false) {
                Text(model.translation).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The card's language as a small uppercase menu; the source side can detect it.
    private func languageMenu(source: Bool) -> some View {
        let code = source ? (model.from ?? model.detected) : model.to
        let auto = source && model.from == nil
        let title = (code.map(Languages.label) ?? "Detect") + (auto ? " · auto" : "")
        return Menu {
            if source {
                Toggle("Detect automatically", isOn: Binding(get: { model.from == nil }, set: { on in
                    guard on else { return }
                    model.from = nil
                    model.run()
                }))
                Divider()
            }
            ForEach(Languages.all, id: \.self) { c in
                Toggle(Languages.label(c), isOn: Binding(get: { source ? model.from == c : model.to == c }, set: { _ in
                    if source { model.from = c } else { model.to = c }
                    model.run()
                }))
            }
        } label: {
            Text(title.uppercased() + "  ▾").font(.system(size: 9.5, weight: .bold)).tracking(0.5)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(editing)
        .help(source ? "Language of the text" : "Translate into")
    }

    // MARK: - Pronunciation

    /// IPA for English, pinyin for Chinese; practice is for English.
    private func pronunciationCard(_ language: String) -> some View {
        let english = language == "en"
        return NotchCard {
            NotchCardHeader(title: "Pronunciation", symbol: "waveform", tint: .mint, detail: english ? "IPA" : "Pinyin") {
                if model.pronounceable.count > 1 {
                    NotchSegmented(options: model.pronounceable.map { ($0, Languages.label($0)) }, selection: language) { model.pronounce = $0 }
                }
                if english {
                    NotchSegmented(options: Pronunciation.Accent.allCases.map { ($0, $0.label) }, selection: model.accent) { model.accent = $0 }
                }
                NotchSegmented(options: SpeechCoach.speeds.map { ($0, $0 == 1 ? "1×" : String(format: "%g×", $0)) },
                               selection: model.speed) { model.speed = $0 }
                copyChip(model.words.map { english ? "\($0.text) /\($0.ipa ?? "?")/" : "\($0.text) \($0.ipa ?? "")" }.joined(separator: " "),
                         help: english ? "Copy the IPA" : "Copy the pinyin")
                if english, let target = model.englishText {
                    if coach.listening {
                        NotchChip(title: "Stop", symbol: "stop.fill", tint: .red, help: "Stop and score") { coach.stopPractice() }
                    } else {
                        NotchChip(title: "Practice", symbol: "mic.fill", prominent: true, help: "Read the English line aloud and get a score") {
                            coach.startPractice(target: target, accent: model.accent)
                        }
                    }
                }
            }
            let score = currentScore
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if model.words.isEmpty {
                        Text("Looking up…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    }
                    ForEach(model.words) { word in
                        wordChip(word, language: language, said: score.flatMap { word.id < $0.words.count ? $0.words[word.id].said : nil })
                    }
                }
            }
            .frame(height: 32)
            practiceFooter(score)
        }
    }

    /// The practice result, if it's for the words shown.
    private var currentScore: SpeechScore.Result? {
        guard let result = coach.result, result.words.map(\.word) == model.words.map(\.text) else { return nil }
        return result
    }

    private func wordChip(_ word: Pronunciation.Word, language: String, said: Bool?) -> some View {
        let fill: Color = isSpoken(word) ? .accentColor.opacity(0.55)
            : said == true ? .green.opacity(0.24) : said == false ? .red.opacity(0.3) : .white.opacity(0.06)
        return VStack(spacing: 1) {
            Text(word.text).font(.system(size: 11, weight: .semibold))
            Text(word.ipa.map { "/\($0)/" } ?? " ").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
        .contentShape(Rectangle())
        .onTapGesture { coach.speak(word.text, language: language == "en" ? model.accent.speechLanguage : language, speed: model.speed) }
        .help("Click to hear \(word.text)")
    }

    /// The word being read aloud right now, if the pronounced side is what's being read.
    private func isSpoken(_ word: Pronunciation.Word) -> Bool {
        guard let range = coach.spokenRange, let text = model.pronouncedText, reading == text,
              let r = Range(range, in: text) else { return false }
        return text[r].caseInsensitiveCompare(word.text) == .orderedSame
    }

    @ViewBuilder private func practiceFooter(_ score: SpeechScore.Result?) -> some View {
        if let problem = coach.problem {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                Text(problem.text).lineLimit(1)
                if let url = problem.settings {
                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.plain).underline()
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.orange)
        } else if coach.listening {
            HStack(spacing: 6) {
                Image(systemName: "waveform").foregroundStyle(.red).symbolEffect(.variableColor.iterative)
                Text(coach.heard.isEmpty ? "Listening… read the English line aloud" : coach.heard).lineLimit(1)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
        } else if let score {
            HStack(spacing: 6) {
                Text("\(score.percent)%").font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(score.percent >= 80 ? .green : score.percent >= 50 ? .orange : .red)
                Text(score.percent == 100 ? "Every word came through. Try 0.75× faster next."
                     : "Red words weren't heard clearly: tap one to hear it, then practise again.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
    }

    // MARK: - Empty and phrase book

    private var emptyCard: some View {
        NotchCard(grows: true) {
            VStack(spacing: 8) {
                Image(systemName: "character.bubble.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.mint)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.mint.opacity(0.15)))
                Text("Select text anywhere and press ⌃⌥C").font(.system(size: 12.5, weight: .semibold))
                Text("English · Chinese · Vietnamese — or click here to type").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { startEditing() }
    }

    private var bookCard: some View {
        let entries = book.entries.sorted { ($0.saved ? 1 : 0, $0.date) > ($1.saved ? 1 : 0, $1.date) }
        let starred = entries.filter(\.saved).count
        return NotchCard(grows: true) {
            NotchCardHeader(title: "Phrase book", symbol: "book.fill", tint: .yellow,
                            detail: entries.isEmpty ? nil : "\(starred) starred · \(entries.count) in all")
            if entries.isEmpty {
                Text("Your translations show up here; star the ones to keep.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(entries) { entry in
                            PhraseRow(entry: entry) {
                                model.show(entry)
                                withAnimation(.easeOut(duration: 0.15)) { showingBook = false }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Editing

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Type or paste text", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13, weight: .medium)).lineLimit(1...4)
                .focused($focused)
                .onSubmit { commitEdit() }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                NotchChip(title: "Cancel", quiet: true) { endEditing() }
                NotchChip(title: "Translate", symbol: "return", prominent: true) { commitEdit() }
            }
        }
        .onExitCommand { endEditing() }
    }

    private func startEditing() {
        draft = model.source
        editing = true
        state.replying = true
        // The panel becomes key on the next turn; focus after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }

    private func commitEdit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        endEditing()
        guard !text.isEmpty else { return }
        model.translate(text)
    }

    private func endEditing() {
        editing = false
        focused = false
        if state.replying { state.replying = false }
    }

    // MARK: - Small parts

    /// Reads `text` aloud (English in the chosen accent); Stop while it's the one being read.
    private func listenChip(_ text: String, language: String?) -> some View {
        let active = coach.speaking && reading == text
        return NotchChip(symbol: active ? "stop.fill" : "speaker.wave.2.fill", quiet: true, help: active ? "Stop" : "Listen") {
            if active { coach.stopSpeaking(); return }
            reading = text
            let voice = Languages.base(language) == "en" ? model.accent.speechLanguage : language ?? "en"
            coach.speak(text, language: voice, speed: model.speed)
        }
        .disabled(text.isEmpty)
    }

    private func copyChip(_ text: String, help: String) -> some View {
        let done = copied == text && !text.isEmpty
        return NotchChip(symbol: done ? "checkmark" : "doc.on.doc", tint: done ? .green : nil, quiet: true, help: help) { copy(text) }
            .disabled(text.isEmpty)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ClipboardHistory.shared.ignoreCurrentChange()
        copied = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == text { copied = nil } }
    }
}

/// A phrase book entry: star, the text → its translation, the languages; click to open it.
private struct PhraseRow: View {
    let entry: PhraseBook.Entry
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button { PhraseBook.shared.toggleSaved(source: entry.source, to: entry.to) } label: {
                Image(systemName: entry.saved ? "star.fill" : "star").foregroundStyle(entry.saved ? .yellow : .white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help(entry.saved ? "Unstar" : "Star")
            Text(entry.source).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: 210, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.35))
            Text(entry.translation).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(Self.short(entry.from)) → \(Self.short(entry.to))").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(0.35))
            Button { PhraseBook.shared.remove(entry.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(hovering ? 0.6 : 0)).help("Remove")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hovering ? 0.09 : 0.04)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }

    static func short(_ code: String) -> String { code == "auto" ? "AUTO" : Languages.base(code).uppercased() }
}
