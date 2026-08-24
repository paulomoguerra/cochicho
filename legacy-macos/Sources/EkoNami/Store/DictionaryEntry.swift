import Foundation

/// One thing the dictionary knows. Two kinds, because the jobs are genuinely different:
///
/// - `.term` — a word the engine should know exists: "Anthropic". Feeds engine biasing only.
/// - `.correction` — when you hear X, write Y: "cloud code" → "Claude Code". Feeds both
///   biasing (on Y) and the deterministic correction pass (X → Y).
struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case term
        case correction
    }

    var id: UUID
    var kind: Kind

    /// The correct text — what gets written and what the engine gets biased toward.
    var write: String

    /// For `.correction` only: the X in "when you hear X". Empty for `.term`.
    var hear: String

    /// Disabled entries stay in the file but stop affecting anything.
    var isEnabled: Bool

    init(id: UUID = UUID(), kind: Kind, write: String, hear: String = "", isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.write = write
        self.hear = hear
        self.isEnabled = isEnabled
    }

    static func term(_ word: String) -> DictionaryEntry {
        DictionaryEntry(kind: .term, write: word)
    }

    static func correction(hear: String, write: String) -> DictionaryEntry {
        DictionaryEntry(kind: .correction, write: write, hear: hear)
    }
}

/// One correction that actually fired, kept so history can show whether the dictionary is
/// earning its place.
struct AppliedCorrection: Codable, Hashable, Sendable {
    let from: String
    let to: String
    let count: Int
}
