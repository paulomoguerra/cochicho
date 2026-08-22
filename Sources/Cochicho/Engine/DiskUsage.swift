import Foundation

/// Total allocated bytes under a folder, walked off the calling thread.
func directorySize(at folder: URL) async -> Int64 {
    await Task.detached(priority: .utility) {
        measureFolder(folder)
    }.value
}

/// Synchronous on purpose: `FileManager.enumerator` can't be iterated from an async
/// context (its iterator isn't concurrency-safe).
private func measureFolder(_ folder: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
    ) else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        total += Int64(values?.totalFileAllocatedSize ?? 0)
    }
    return total
}
