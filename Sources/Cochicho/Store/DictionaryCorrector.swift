import Foundation

/// Rewrites transcribed text using the dictionary's correction pairs.
///
/// This is the guaranteed half of the dictionary — engine biasing only raises the odds.
/// Three rules, all load-bearing:
///
/// **Longest match first.** "Claude Code" is applied before "Claude", so the longer rule
/// isn't pre-empted by a shorter one that overlaps it.
///
/// **Whole matches only.** Patterns are fenced by letter/digit lookarounds, so a rule for
/// "cloud code" can never touch "Cloudflare".
///
/// **Glued words still match.** Engines run words together — "CloudCode", "cloud-code" —
/// so the gap between phrase parts matches optional whitespace or hyphens.
struct DictionaryCorrector: Sendable {
    private let rules: [Rule]

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let replacement: String
        let trigger: String
    }

    init(entries: [DictionaryEntry]) {
        let corrections = entries
            .filter { $0.isEnabled && $0.kind == .correction }
            .filter { !$0.hear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.hear.count > $1.hear.count }

        rules = corrections.compactMap { entry in
            guard let regex = Self.makeRegex(for: entry.hear) else { return nil }
            return Rule(
                regex: regex,
                replacement: NSRegularExpression.escapedTemplate(for: entry.write),
                trigger: entry.hear
            )
        }
    }

    var isEmpty: Bool { rules.isEmpty }

    /// Applies every rule in order.
    /// - Returns: the rewritten text, plus one `AppliedCorrection` per rule that fired.
    func apply(to text: String) -> (text: String, applied: [AppliedCorrection]) {
        guard !rules.isEmpty, !text.isEmpty else { return (text, []) }

        // Normalize to NFC before matching — macOS hands back decomposed strings in several
        // places, and "café" decomposed is five scalars where composed is four. Pattern and
        // text must be in the same form or an accented trigger silently never matches.
        var result = text.precomposedStringWithCanonicalMapping
        var applied: [AppliedCorrection] = []

        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            let matches = rule.regex.numberOfMatches(in: result, range: range)
            guard matches > 0 else { continue }

            // Record what the engine actually produced, not the rule's trigger.
            let firstMatch = rule.regex.firstMatch(in: result, range: range)
            let heard = firstMatch
                .flatMap { Range($0.range, in: result) }
                .map { String(result[$0]) } ?? rule.trigger

            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: rule.replacement
            )

            applied.append(AppliedCorrection(
                from: heard,
                to: rule.replacement.replacingOccurrences(of: "\\", with: ""),
                count: matches
            ))
        }

        return (result, applied)
    }

    /// Builds the pattern for one trigger phrase. Parts joined with `[\s\-]*` catch
    /// "CloudCode" and "Cloud-Code" alongside the spaced form. Fences are lookarounds on
    /// letters and digits rather than `\b`, which would treat a trailing hyphen as a
    /// boundary and let a rule bite into a longer word.
    private static func makeRegex(for trigger: String) -> NSRegularExpression? {
        let parts = trigger
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\t" })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }

        guard !parts.isEmpty else { return nil }

        let body = parts.joined(separator: "[\\s\\-]*")
        let pattern = "(?<![\\p{L}\\p{N}])\(body)(?![\\p{L}\\p{N}])"

        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

extension DictionaryCorrector {
    /// Kept deliberately short — these models drift when given a long context list: on
    /// quiet or ambiguous audio they start inventing text from the primed vocabulary.
    static let biasLimit = 40

    /// - Returns: the correct spellings, first entries first, capped at `biasLimit`.
    static func biasPhrases(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var phrases: [String] = []

        for entry in entries where entry.isEnabled {
            let phrase = entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, seen.insert(phrase.lowercased()).inserted else { continue }
            phrases.append(phrase)
            if phrases.count == biasLimit { break }
        }

        return phrases
    }
}
