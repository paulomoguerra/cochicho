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
        let dir = support.appendingPathComponent("Cochicho", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func record(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    // Aggregates for the stats card.
    var totalWords: Int { entries.reduce(0) { $0 + $1.wordCount } }
    var totalSeconds: Double { entries.reduce(0) { $0 + $1.audioSeconds } }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
