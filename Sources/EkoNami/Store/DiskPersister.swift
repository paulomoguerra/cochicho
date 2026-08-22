import Foundation

/// Encodes and writes one store's JSON file off the main thread.
///
/// Stores mutate on the main actor but must not pay for encoding + disk I/O there. Each
/// save is handed off as a value snapshot; the actor serializes the writes. Saves carry a
/// monotonic version so a stale snapshot that arrives late is dropped instead of
/// overwriting newer data — unstructured tasks give no ordering guarantee on their own.
actor DiskPersister {
    private let url: URL
    private let encoder: JSONEncoder
    private var lastWritten = 0

    init(url: URL, iso8601Dates: Bool = false) {
        self.url = url
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if iso8601Dates { encoder.dateEncodingStrategy = .iso8601 }
        self.encoder = encoder
    }

    func save<T: Encodable & Sendable>(_ snapshot: T, version: Int) {
        guard version > lastWritten else { return }
        lastWritten = version
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
