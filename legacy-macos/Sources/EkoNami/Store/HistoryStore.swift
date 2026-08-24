import Foundation
import Observation

/// One finished dictation.
struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var date: Date
    var text: String
    var engine: String
    var language: String
    /// How long the mic was open.
    var audioSeconds: Double
    /// Wait from stop to text landing — the latency the user actually feels.
    var processSeconds: Double
    var corrections: [AppliedCorrection]?

    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// Transcription memory, persisted as JSON in Application Support.
@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    /// Newest first.
    private(set) var entries: [HistoryEntry] = []

    /// Kept bounded so the file and the list stay fast; nobody scrolls past this.
    private static let cap = 500

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("EkoNami", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private let persister = DiskPersister(url: HistoryStore.fileURL, iso8601Dates: true)
    private var saveVersion = 0

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = saved
        }
        totalWords = entries.reduce(0) { $0 + $1.wordCount }
    }

    func record(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        totalWords += entry.wordCount
        if entries.count > Self.cap {
            for dropped in entries[Self.cap...] { totalWords -= dropped.wordCount }
            entries.removeLast(entries.count - Self.cap)
        }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        totalWords -= entries[index].wordCount
        entries.remove(at: index)
        save()
    }

    func clear() {
        entries.removeAll()
        totalWords = 0
        save()
    }

    // Aggregates for the stats card. `totalWords` is kept incrementally — recomputing it
    // re-tokenizes every stored text, and the stats card reads it on every render.
    private(set) var totalWords = 0
    var totalSeconds: Double { entries.reduce(0) { $0 + $1.audioSeconds } }

    private func save() {
        saveVersion += 1
        let version = saveVersion
        let snapshot = entries
        Task { await persister.save(snapshot, version: version) }
    }
}
