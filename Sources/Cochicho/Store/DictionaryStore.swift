import Foundation
import Observation

/// The user's dictionary, persisted as JSON in Application Support. Seeded with
/// `DefaultDictionary` on first launch; after that the file is the source of truth.
@MainActor
@Observable
final class DictionaryStore {
    static let shared = DictionaryStore()

    private(set) var entries: [DictionaryEntry] = []

    /// Rebuilt lazily whenever entries change — regex compilation isn't free.
    private var cachedCorrector: DictionaryCorrector?

    var corrector: DictionaryCorrector {
        if let cachedCorrector { return cachedCorrector }
        let built = DictionaryCorrector(entries: entries)
        cachedCorrector = built
        return built
    }

    var biasPhrases: [String] { DictionaryCorrector.biasPhrases(from: entries) }

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Cochicho", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.json")
    }

    private let persister = DiskPersister(url: DictionaryStore.fileURL)
    private var saveVersion = 0

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            entries = saved
        } else {
            entries = DefaultDictionary.entries
            save()
        }
    }

    func add(_ entry: DictionaryEntry) {
        entries.insert(entry, at: 0)
        mutated()
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        mutated()
    }

    func remove(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        mutated()
    }

    func toggle(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isEnabled.toggle()
        mutated()
    }

    /// Re-seeds any default entry the user hasn't got (by write+hear pair), never
    /// duplicating or overriding their edits.
    func restoreDefaults() {
        let existing = Set(entries.map { "\($0.hear.lowercased())→\($0.write.lowercased())" })
        let missing = DefaultDictionary.entries.filter {
            !existing.contains("\($0.hear.lowercased())→\($0.write.lowercased())")
        }
        entries.append(contentsOf: missing)
        mutated()
    }

    private func mutated() {
        cachedCorrector = nil
        save()
    }

    private func save() {
        saveVersion += 1
        let version = saveVersion
        let snapshot = entries
        Task { await persister.save(snapshot, version: version) }
    }
}
