import AppKit

/// Apps asking for attention (a message arrived, a download finished: what makes Apple's Dock
/// bounce), from LaunchServices' own notifications through `lsappinfo listen`. No public API
/// reports other apps' requests, and polling missed the informational ones, which last about 1 s.
/// ponytail: a child process streaming text; a private LaunchServices callback would avoid it.
@MainActor
final class AttentionWatch {
    static let shared = AttentionWatch()
    /// The app, and whether it wants attention now (false once it's answered or gave up).
    var onChange: ((NSRunningApplication, Bool) -> Void)?
    private var process: Process?
    private var buffer = Data()
    private var running = false
    nonisolated private static let restartDelay: TimeInterval = 5

    func start() {
        running = true
        guard process == nil else { return }
        Self.endOrphans()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        p.arguments = ["listen", "+wantsAttentionChanged", "forever"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(chunk) } }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.process = nil
                    if self.running { self.start() }
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("win-tab: couldn't watch attention requests: \(error)")
        }
    }

    /// A listener from a run that was killed has no reader left and only exits at its next write;
    /// end it now (its parent is launchd by then).
    private static func endOrphans() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-P", "1", "-f", #"lsappinfo listen \+wantsAttentionChanged forever"#]
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }

    func stop() {
        running = false
        process?.terminate()
        process = nil
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = AttentionLine.parse(line) else { continue }
            // The notification names the app by its LaunchServices ID; ask for its pid off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let pid = AttentionLine.pid(of: event.asn) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
                        self.onChange?(app, event.wants)
                    }
                }
            }
        }
    }
}

/// One line of `lsappinfo listen +wantsAttentionChanged`.
struct AttentionLine: Equatable {
    let asn: String
    let wants: Bool

    /// `… "LSASN"=ASN:0x0-0x51e81e3:, … "LSWantsAttention"=true } …`
    static func parse(_ line: String) -> AttentionLine? {
        guard line.contains("WantsAttentionChanged"),
              let key = line.range(of: #""LSASN"="#),
              let asn = line.range(of: #"ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+:"#, options: .regularExpression,
                                   range: key.upperBound..<line.endIndex) else { return nil }
        return AttentionLine(asn: String(line[asn]), wants: line.contains(#""LSWantsAttention"=true"#))
    }

    /// `pid = 677` from `lsappinfo info -only pid <ASN>` (or `"pid"=677` as in notifications).
    static func pid(fromInfo text: String) -> pid_t? {
        guard let r = text.range(of: #"\bpid"? ?= ?[0-9]+"#, options: .regularExpression),
              let digits = text[r].range(of: "[0-9]+", options: .regularExpression) else { return nil }
        return pid_t(text[r][digits])
    }

    static func pid(of asn: String) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        p.arguments = ["info", "-only", "pid", asn]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return pid(fromInfo: String(decoding: data, as: UTF8.self))
    }
}
