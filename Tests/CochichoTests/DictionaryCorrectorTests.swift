import Testing
@testable import Cochicho

/// The corrector is the deterministic half of the dictionary — the pass that *guarantees*
/// spelling. Every rule here is load-bearing and subtle enough to break silently in a
/// refactor, which is why this file exists.
struct DictionaryCorrectorTests {

    private func corrector(_ pairs: [(hear: String, write: String)]) -> DictionaryCorrector {
        DictionaryCorrector(entries: pairs.map { .correction(hear: $0.hear, write: $0.write) })
    }

    // MARK: - Basic replacement

    @Test func replacesASimplePair() {
        let (text, applied) = corrector([("cloud code", "Claude Code")])
            .apply(to: "abre o cloud code aí")
        #expect(text == "abre o Claude Code aí")
        #expect(applied.count == 1)
        #expect(applied[0].to == "Claude Code")
    }

    @Test func isCaseInsensitive() {
        let (text, _) = corrector([("anthropic", "Anthropic")])
            .apply(to: "a ANTHROPIC lançou")
        #expect(text == "a Anthropic lançou")
    }

    @Test func replacesEveryOccurrenceAndCountsThem() {
        let (text, applied) = corrector([("uber", "Uber")])
            .apply(to: "uber pra cá, uber pra lá")
        #expect(text == "Uber pra cá, Uber pra lá")
        #expect(applied[0].count == 2)
    }

    @Test func untouchedTextComesBackVerbatim() {
        let (text, applied) = corrector([("cloud code", "Claude Code")])
            .apply(to: "nada a corrigir aqui")
        #expect(text == "nada a corrigir aqui")
        #expect(applied.isEmpty)
    }

    // MARK: - Whole-word fencing

    @Test func neverBitesIntoALongerWord() {
        let (text, _) = corrector([("cloud", "Claude")])
            .apply(to: "hospedado na Cloudflare")
        #expect(text == "hospedado na Cloudflare")
    }

    @Test func digitsFenceTheSameAsLetters() {
        let (text, _) = corrector([("gpt", "GPT")])
            .apply(to: "o gpt4 respondeu")
        #expect(text == "o gpt4 respondeu")
    }

    @Test func punctuationDoesNotBlockAMatch() {
        let (text, _) = corrector([("cloud code", "Claude Code")])
            .apply(to: "usa o cloud code, sempre")
        #expect(text == "usa o Claude Code, sempre")
    }

    // MARK: - Glued and hyphenated forms

    @Test func matchesGluedWords() {
        let (text, _) = corrector([("cloud code", "Claude Code")])
            .apply(to: "abre o CloudCode")
        #expect(text == "abre o Claude Code")
    }

    @Test func matchesHyphenatedForms() {
        let (text, _) = corrector([("cloud code", "Claude Code")])
            .apply(to: "o cloud-code travou")
        #expect(text == "o Claude Code travou")
    }

    // MARK: - Longest match first

    @Test func longerRuleWinsOverItsPrefix() {
        let (text, _) = corrector([("claude", "Claude"), ("claude code", "Claude Code")])
            .apply(to: "abre o claude code")
        #expect(text == "abre o Claude Code")
    }

    // MARK: - Unicode

    @Test func accentedTriggerMatchesDecomposedText() {
        // "café" typed as e + combining acute — what macOS hands back in several places.
        let decomposed = "um cafe\u{0301} por favor"
        let (text, _) = corrector([("café", "Café Especial")]).apply(to: decomposed)
        #expect(text == "um Café Especial por favor")
    }

    // MARK: - Entry filtering

    @Test func disabledEntriesDoNothing() {
        var entry = DictionaryEntry.correction(hear: "uber", write: "Uber")
        entry.isEnabled = false
        let (text, applied) = DictionaryCorrector(entries: [entry]).apply(to: "chama um uber")
        #expect(text == "chama um uber")
        #expect(applied.isEmpty)
    }

    @Test func termEntriesNeverRewrite() {
        let (text, applied) = DictionaryCorrector(entries: [.term("Anthropic")])
            .apply(to: "anthropic é uma empresa")
        #expect(text == "anthropic é uma empresa")
        #expect(applied.isEmpty)
    }

    @Test func blankTriggersAreIgnored() {
        let corrector = DictionaryCorrector(entries: [.correction(hear: "   ", write: "X")])
        #expect(corrector.isEmpty)
    }

    // MARK: - Replacement safety

    @Test func dollarSignsInReplacementAreLiteral() {
        // `$0` in a template means "the whole match" unless escaped — a rule writing "$100"
        // must not expand to the matched text.
        let (text, _) = corrector([("cem dólares", "$100")])
            .apply(to: "custa cem dólares hoje")
        #expect(text == "custa $100 hoje")
    }

    @Test func appliedRecordsWhatTheEngineActuallySaid() {
        let (_, applied) = corrector([("cloud code", "Claude Code")])
            .apply(to: "abre o Cloud-Code")
        #expect(applied[0].from == "Cloud-Code")
    }
}

struct BiasPhrasesTests {

    @Test func capsAtTheLimitInEntryOrder() {
        let entries = (0..<60).map { DictionaryEntry.term("palavra\($0)") }
        let phrases = DictionaryCorrector.biasPhrases(from: entries)
        #expect(phrases.count == DictionaryCorrector.biasLimit)
        #expect(phrases.first == "palavra0")
    }

    @Test func dedupesCaseInsensitively() {
        let entries = [DictionaryEntry.term("Figma"), .term("figma"), .term("Linear")]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Figma", "Linear"])
    }

    @Test func skipsDisabledAndBlankEntries() {
        var off = DictionaryEntry.term("Oculta")
        off.isEnabled = false
        let entries = [off, .term("  "), .term("Visível")]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Visível"])
    }
}
