//! Port 1:1 de legacy-macos `DictionaryCorrector.swift` — a metade determinística do
//! dicionário, a passada que *garante* a grafia. Três regras load-bearing:
//!
//! **Longest match first.** "Claude Code" aplica antes de "Claude".
//! **Whole matches only.** Padrões cercados por lookarounds de letra/dígito.
//! **Glued words still match.** "CloudCode", "cloud-code" casam com o gatilho espaçado.

use fancy_regex::{Regex, RegexBuilder};
use unicode_normalization::UnicodeNormalization;

use crate::core::dictionary::{AppliedCorrection, DictionaryEntry, EntryKind};

struct Rule {
    regex: Regex,
    replacement: String,
}

pub struct DictionaryCorrector {
    rules: Vec<Rule>,
}

impl DictionaryCorrector {
    pub fn new(entries: &[DictionaryEntry]) -> Self {
        let mut corrections: Vec<&DictionaryEntry> = entries
            .iter()
            .filter(|e| e.is_enabled && e.kind == EntryKind::Correction)
            .filter(|e| !e.hear.trim().is_empty())
            .collect();
        corrections.sort_by(|a, b| b.hear.len().cmp(&a.hear.len()));

        let rules = corrections
            .into_iter()
            .filter_map(|entry| {
                Self::make_regex(&entry.hear).map(|regex| Rule {
                    regex,
                    replacement: entry.write.clone(),
                })
            })
            .collect();

        Self { rules }
    }

    fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }

    /// Aplica toda regra em ordem. Retorna o texto reescrito + um AppliedCorrection
    /// por regra que disparou.
    pub fn apply(&self, text: &str) -> (String, Vec<AppliedCorrection>) {
        if self.is_empty() || text.is_empty() {
            return (text.to_string(), Vec::new());
        }

        // NFC antes de casar — engines podem devolver strings decompostas ("café" como
        // e + acento combinante), e padrão e texto precisam estar na mesma forma.
        let mut result: String = text.nfc().collect();
        let mut applied = Vec::new();

        for rule in &self.rules {
            let matches: Vec<(usize, usize)> = rule
                .regex
                .find_iter(&result)
                .filter_map(|m| m.ok().map(|m| (m.start(), m.end())))
                .collect();
            if matches.is_empty() {
                continue;
            }

            // Registra o que a engine realmente produziu, não o gatilho da regra.
            let (first_start, first_end) = matches[0];
            let heard = result[first_start..first_end].to_string();
            let count = matches.len();

            // Substituição manual, de trás pra frente: o replacement é literal
            // ("$100" não pode expandir para o match, como aconteceria com templates).
            let mut next = result.clone();
            for (start, end) in matches.into_iter().rev() {
                next.replace_range(start..end, &rule.replacement);
            }
            result = next;

            applied.push(AppliedCorrection {
                from: heard,
                to: rule.replacement.clone(),
                count,
            });
        }

        (result, applied)
    }

    /// Partes unidas por `[\s\-]*` capturam "CloudCode" e "Cloud-Code" além da forma
    /// espaçada. Cercas são lookarounds sobre letras/dígitos em vez de `\b`, que
    /// trataria um hífen final como fronteira e deixaria a regra morder palavra maior.
    fn make_regex(trigger: &str) -> Option<Regex> {
        let nfc: String = trigger.nfc().collect();
        let parts: Vec<String> = nfc
            .trim()
            .split([' ', '-', '\t'])
            .filter(|p| !p.is_empty())
            .map(regex::escape)
            .collect();

        if parts.is_empty() {
            return None;
        }

        let body = parts.join(r"[\s\-]*");
        let pattern = format!(r"(?<![\p{{L}}\p{{N}}]){body}(?![\p{{L}}\p{{N}}])");

        RegexBuilder::new(&pattern)
            .case_insensitive(true)
            .build()
            .ok()
    }

    /// Deliberadamente curto — modelos derivam com listas de contexto longas: em áudio
    /// quieto ou ambíguo começam a inventar texto do vocabulário estimulado.
    pub const BIAS_LIMIT: usize = 40;

    /// As grafias corretas, na ordem das entradas, limitadas a BIAS_LIMIT.
    pub fn bias_phrases(entries: &[DictionaryEntry]) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        let mut phrases = Vec::new();

        for entry in entries.iter().filter(|e| e.is_enabled) {
            let phrase = entry.write.trim();
            if phrase.is_empty() || !seen.insert(phrase.to_lowercase()) {
                continue;
            }
            phrases.push(phrase.to_string());
            if phrases.len() == Self::BIAS_LIMIT {
                break;
            }
        }

        phrases
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::dictionary::DictionaryEntry;

    fn corrector(pairs: &[(&str, &str)]) -> DictionaryCorrector {
        let entries: Vec<DictionaryEntry> = pairs
            .iter()
            .map(|(hear, write)| DictionaryEntry::correction(hear, write))
            .collect();
        DictionaryCorrector::new(&entries)
    }

    // MARK: - Basic replacement

    #[test]
    fn replaces_a_simple_pair() {
        let (text, applied) =
            corrector(&[("cloud code", "Claude Code")]).apply("abre o cloud code aí");
        assert_eq!(text, "abre o Claude Code aí");
        assert_eq!(applied.len(), 1);
        assert_eq!(applied[0].to, "Claude Code");
    }

    #[test]
    fn is_case_insensitive() {
        let (text, _) = corrector(&[("anthropic", "Anthropic")]).apply("a ANTHROPIC lançou");
        assert_eq!(text, "a Anthropic lançou");
    }

    #[test]
    fn replaces_every_occurrence_and_counts_them() {
        let (text, applied) = corrector(&[("uber", "Uber")]).apply("uber pra cá, uber pra lá");
        assert_eq!(text, "Uber pra cá, Uber pra lá");
        assert_eq!(applied[0].count, 2);
    }

    #[test]
    fn untouched_text_comes_back_verbatim() {
        let (text, applied) =
            corrector(&[("cloud code", "Claude Code")]).apply("nada a corrigir aqui");
        assert_eq!(text, "nada a corrigir aqui");
        assert!(applied.is_empty());
    }

    // MARK: - Whole-word fencing

    #[test]
    fn never_bites_into_a_longer_word() {
        let (text, _) = corrector(&[("cloud", "Claude")]).apply("hospedado na Cloudflare");
        assert_eq!(text, "hospedado na Cloudflare");
    }

    #[test]
    fn digits_fence_the_same_as_letters() {
        let (text, _) = corrector(&[("gpt", "GPT")]).apply("o gpt4 respondeu");
        assert_eq!(text, "o gpt4 respondeu");
    }

    #[test]
    fn punctuation_does_not_block_a_match() {
        let (text, _) =
            corrector(&[("cloud code", "Claude Code")]).apply("usa o cloud code, sempre");
        assert_eq!(text, "usa o Claude Code, sempre");
    }

    // MARK: - Glued and hyphenated forms

    #[test]
    fn matches_glued_words() {
        let (text, _) = corrector(&[("cloud code", "Claude Code")]).apply("abre o CloudCode");
        assert_eq!(text, "abre o Claude Code");
    }

    #[test]
    fn matches_hyphenated_forms() {
        let (text, _) = corrector(&[("cloud code", "Claude Code")]).apply("o cloud-code travou");
        assert_eq!(text, "o Claude Code travou");
    }

    // MARK: - Longest match first

    #[test]
    fn longer_rule_wins_over_its_prefix() {
        let (text, _) = corrector(&[("claude", "Claude"), ("claude code", "Claude Code")])
            .apply("abre o claude code");
        assert_eq!(text, "abre o Claude Code");
    }

    // MARK: - Unicode

    #[test]
    fn accented_trigger_matches_decomposed_text() {
        // "café" digitado como e + agudo combinante.
        let decomposed = "um cafe\u{301} por favor";
        let (text, _) = corrector(&[("café", "Café Especial")]).apply(decomposed);
        assert_eq!(text, "um Café Especial por favor");
    }

    // MARK: - Entry filtering

    #[test]
    fn disabled_entries_do_nothing() {
        let mut entry = DictionaryEntry::correction("uber", "Uber");
        entry.is_enabled = false;
        let (text, applied) = DictionaryCorrector::new(&[entry]).apply("chama um uber");
        assert_eq!(text, "chama um uber");
        assert!(applied.is_empty());
    }

    #[test]
    fn term_entries_never_rewrite() {
        let (text, applied) = DictionaryCorrector::new(&[DictionaryEntry::term("Anthropic")])
            .apply("anthropic é uma empresa");
        assert_eq!(text, "anthropic é uma empresa");
        assert!(applied.is_empty());
    }

    #[test]
    fn blank_triggers_are_ignored() {
        let corrector = DictionaryCorrector::new(&[DictionaryEntry::correction("   ", "X")]);
        assert!(corrector.is_empty());
    }

    // MARK: - Replacement safety

    #[test]
    fn dollar_signs_in_replacement_are_literal() {
        let (text, _) = corrector(&[("cem dólares", "$100")]).apply("custa cem dólares hoje");
        assert_eq!(text, "custa $100 hoje");
    }

    #[test]
    fn applied_records_what_the_engine_actually_said() {
        let (_, applied) = corrector(&[("cloud code", "Claude Code")]).apply("abre o Cloud-Code");
        assert_eq!(applied[0].from, "Cloud-Code");
    }

    // MARK: - Bias phrases

    #[test]
    fn bias_caps_at_the_limit_in_entry_order() {
        let entries: Vec<DictionaryEntry> = (0..60)
            .map(|i| DictionaryEntry::term(&format!("palavra{i}")))
            .collect();
        let phrases = DictionaryCorrector::bias_phrases(&entries);
        assert_eq!(phrases.len(), DictionaryCorrector::BIAS_LIMIT);
        assert_eq!(phrases.first().map(String::as_str), Some("palavra0"));
    }

    #[test]
    fn bias_dedupes_case_insensitively() {
        let entries = vec![
            DictionaryEntry::term("Figma"),
            DictionaryEntry::term("figma"),
            DictionaryEntry::term("Linear"),
        ];
        assert_eq!(
            DictionaryCorrector::bias_phrases(&entries),
            vec!["Figma", "Linear"]
        );
    }

    #[test]
    fn bias_skips_disabled_and_blank_entries() {
        let mut off = DictionaryEntry::term("Oculta");
        off.is_enabled = false;
        let entries = vec![
            off,
            DictionaryEntry::term("  "),
            DictionaryEntry::term("Visível"),
        ];
        assert_eq!(DictionaryCorrector::bias_phrases(&entries), vec!["Visível"]);
    }
}
