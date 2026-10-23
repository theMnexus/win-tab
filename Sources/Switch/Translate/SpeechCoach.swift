import AppKit
import AVFoundation
import Speech

/// Reading aloud (the Mac's own voices, US or UK, at three speeds, word by word) and speaking
/// practice (on-device recognition, scored word by word). Created when first used; the audio
/// engine only runs while practising.
@MainActor
final class SpeechCoach: NSObject, ObservableObject {
    static let shared = SpeechCoach()

    static let speeds: [Double] = [1, 0.75, 0.5]

    @Published private(set) var speaking = false
    /// Range of the word being read, in the text passed to `speak`.
    @Published private(set) var spokenRange: NSRange?
    @Published private(set) var listening = false
    @Published private(set) var heard = ""
    @Published private(set) var result: SpeechScore.Result?
    /// Why practice can't start (permissions, no recognizer), with the Settings pane that fixes it.
    @Published private(set) var problem: (text: String, settings: URL?)?

    private lazy var synthesizer: AVSpeechSynthesizer = {
        let s = AVSpeechSynthesizer()
        s.delegate = self
        return s
    }()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var target = ""
    private var silenceWork: DispatchWorkItem?
    private var limitWork: DispatchWorkItem?
    private static let silenceTimeout: TimeInterval = 1.5
    private static let practiceLimit: TimeInterval = 20

    // MARK: - Reading aloud

    /// `language`: "en-US", "en-GB", or any language code ("vi" picks a Vietnamese voice).
    func speak(_ text: String, language: String, speed: Double) {
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(for: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        speaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
        spokenRange = nil
    }

    /// A premium or enhanced voice if one is installed, else the language's default voice (not
    /// whichever plain voice comes first: that can be Bubbles or Zarvox).
    static func bestVoice(for code: String) -> AVSpeechSynthesisVoice? {
        let language = Languages.speech(code)
        let better = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language && $0.quality != .default }
        return better.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }

    // MARK: - Speaking practice

    func startPractice(target: String, accent: Pronunciation.Accent) {
        stopSpeaking()
        stopPractice(score: false)
        self.target = target
        result = nil
        heard = ""
        problem = nil
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard status == .authorized else {
                        self.problem = ("Allow Speech Recognition for win-tab", URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"))
                        return
                    }
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard granted else {
                                    self.problem = ("Allow the microphone for win-tab", URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
                                    return
                                }
                                self.beginListening(accent: accent)
                            }
                        }
                    }
                }
            }
        }
    }

    private func beginListening(accent: Pronunciation.Accent) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: accent.speechLanguage)), recognizer.isAvailable else {
            problem = ("Speech recognition isn't available for \(accent.label) English", nil)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Never leaves the Mac; where the on-device model is missing, say so instead of uploading.
        guard recognizer.supportsOnDeviceRecognition else {
            problem = ("On-device recognition isn't installed. Turn on Dictation in Keyboard settings once.", URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"))
            return
        }
        request.requiresOnDeviceRecognition = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = ("The microphone couldn't start: \(error.localizedDescription)", nil)
            return
        }
        self.engine = engine
        self.request = request
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.listening else { return }
                    if let text { self.heard = text; self.armSilence() }
                    if final || error != nil { self.stopPractice(score: true) }
                }
            }
        }
        let limit = DispatchWorkItem { [weak self] in self?.stopPractice(score: true) }
        limitWork = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.practiceLimit, execute: limit)
    }

    /// Stops a moment after the last word heard.
    private func armSilence() {
        silenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopPractice(score: true) }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silenceTimeout, execute: work)
    }

    func stopPractice(score: Bool = true) {
        silenceWork?.cancel()
        limitWork?.cancel()
        guard listening || engine != nil else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        listening = false
        if score { result = SpeechScore.score(target: target, heard: heard) }
    }
}

extension SpeechCoach: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.spokenRange = characterRange } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.speaking = false; self.spokenRange = nil } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.speaking = false; self.spokenRange = nil } }
    }
}
