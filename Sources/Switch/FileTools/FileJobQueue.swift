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
