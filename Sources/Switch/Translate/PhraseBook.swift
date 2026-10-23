import Foundation

/// Translations made with ⌃⌥C or the Translate tab: the last 200, plus everything starred,
/// kept in Application Support. Read from disk the first time it's needed.
@MainActor
final class PhraseBook: ObservableObject {
    static let shared = PhraseBook()

    struct Entry: Identifiable, Codable, Equatable {
        var id = UUID()
        var date: Date
        var source: String
        var translation: String
        var from: String
        var to: String
        var saved = false
    }

    @Published private(set) var entries: [Entry] = []
    private var loaded = false
    private var saveWork: DispatchWorkItem?
    private static let historyCap = 200

    nonisolated private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("win-tab", isDirectory: true).appendingPathComponent("phrasebook.json")
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        let data = try? Data(contentsOf: Self.fileURL)
        entries = data.flatMap { try? JSONDecoder.iso.decode([Entry].self, from: $0) } ?? []
    }

    /// Newest first; the same text into the same language again just moves to the top.
    func record(source: String, translation: String, from: String, to: String) {
        load()
        let old = entries.first { $0.source == source && $0.to == to }
        let rest = entries.filter { !($0.source == source && $0.to == to) }
        let entry = Entry(id: old?.id ?? UUID(), date: Date(), source: source, translation: translation, from: from, to: to, saved: old?.saved ?? false)
        let unsaved = rest.filter { !$0.saved }.prefix(Self.historyCap - 1)
        entries = [entry] + rest.filter(\.saved) + unsaved
        entries.sort { $0.date > $1.date }
        save()
    }

    func isSaved(source: String, to: String) -> Bool {
        entries.contains { $0.source == source && $0.to == to && $0.saved }
    }

    func toggleSaved(source: String, to: String) {
        load()
        entries = entries.map { e in
            guard e.source == source && e.to == to else { return e }
            var copy = e
            copy.saved.toggle()
            return copy
        }
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Written a second after the last change, off the main thread.
    private func save() {
        saveWork?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem {
            let url = Self.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder.iso.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
