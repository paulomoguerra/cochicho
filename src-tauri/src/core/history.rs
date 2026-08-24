//! Port de `HistoryStore.swift`: as últimas 500 transcrições em JSON + contadores de
//! uso (completamente locais — o stats card prova o quanto você usa sem mandar nada
//! pra lugar nenhum).

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::RwLock;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::core::dictionary::AppliedCorrection;
use crate::core::persist::DiskPersister;

const CAP: usize = 500;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub id: Uuid,
    /// O que a engine devolveu, antes da correção.
    pub text: String,
    /// O que foi de fato inserido (depois do dicionário). Igual a `text` se nada disparou.
    pub corrected_text: String,
    #[serde(default)]
    pub corrections: Vec<AppliedCorrection>,
    pub engine: String,
    #[serde(default)]
    pub model: String,
    pub duration_seconds: f64,
    pub word_count: usize,
    pub created_at: DateTime<Utc>,
}

/// Cargos do arquivo de histórico.
#[derive(Default, Serialize, Deserialize)]
struct Snapshot {
    entries: Vec<HistoryEntry>,
    total_words: usize,
    total_seconds: f64,
}

pub struct HistoryStore {
    entries: RwLock<Vec<HistoryEntry>>,
    /// Contadores de uso de toda a vida, incrementais — separados da lista com cap.
    totals: RwLock<(usize, f64)>,
    needs_legacy_trim: RwLock<bool>,
    persister: DiskPersister,
    save_version: AtomicU64,
}

impl HistoryStore {
    pub fn load(path: PathBuf) -> Self {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let raw = std::fs::read(&path).ok();
        let snapshot = raw
            .as_ref()
            .and_then(|data| load_snapshot(data))
            .unwrap_or_default();

        let needs_legacy_trim = snapshot.entries.len() > CAP;
        let mut entries = snapshot.entries;
        if needs_legacy_trim {
            entries.truncate(CAP);
        }

        Self {
            entries: RwLock::new(entries),
            totals: RwLock::new((snapshot.total_words, snapshot.total_seconds)),
            needs_legacy_trim: RwLock::new(needs_legacy_trim),
            persister: DiskPersister::new(path),
            save_version: AtomicU64::new(0),
        }
    }

    pub fn record(&self, mut entry: HistoryEntry) {
        entry.word_count = entry.corrected_text.split_whitespace().count();
        let word_count = entry.word_count;
        let duration = entry.duration_seconds;

        {
            let mut entries = self.entries.write().unwrap();
            entries.insert(0, entry);
            entries.truncate(CAP);
        }
        {
            let mut totals = self.totals.write().unwrap();
            totals.0 += word_count;
            totals.1 += duration;
        }
        self.save();
    }

    pub fn entries(&self) -> Vec<HistoryEntry> {
        self.entries.read().unwrap().clone()
    }

    pub fn totals(&self) -> (usize, f64) {
        *self.totals.read().unwrap()
    }

    pub fn clear(&self) {
        self.entries.write().unwrap().clear();
        self.save();
    }

    fn save(&self) {
        let version = self.save_version.fetch_add(1, Ordering::SeqCst) + 1;
        let mut needs_trim = self.needs_legacy_trim.write().unwrap();
        if *needs_trim {
            // Migração única: o arquivo velho pode ter milhares de entradas; o primeiro
            // save do formato novo já grava cortado no cap.
            *needs_trim = false;
        }
        let (total_words, total_seconds) = *self.totals.read().unwrap();
        let snapshot = Snapshot {
            entries: self.entries.read().unwrap().clone(),
            total_words,
            total_seconds,
        };
        self.persister.save(snapshot, version);
    }
}

/// Aceita o Snapshot Rust (`{entries,…}`) ou o array legado do app Swift.
fn load_snapshot(data: &[u8]) -> Option<Snapshot> {
    if let Ok(snap) = serde_json::from_slice::<Snapshot>(data) {
        return Some(snap);
    }
    let migrated = crate::core::migration::transform_history(data).ok()?;
    Some(Snapshot {
        entries: migrated.entries,
        total_words: migrated.total_words,
        total_seconds: migrated.total_seconds,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(text: &str) -> HistoryEntry {
        HistoryEntry {
            id: Uuid::new_v4(),
            text: text.to_string(),
            corrected_text: text.to_string(),
            corrections: vec![],
            engine: "whisper".into(),
            model: "ggml-base.bin".into(),
            duration_seconds: 1.5,
            word_count: 0,
            created_at: Utc::now(),
        }
    }

    #[test]
    fn newest_first_and_capped() {
        let dir = std::env::temp_dir().join(format!("ekonami-test-{}", Uuid::new_v4()));
        let store = HistoryStore::load(dir.join("history.json"));
        for i in 0..505 {
            store.record(entry(&format!("entry {i}")));
        }
        let entries = store.entries();
        assert_eq!(entries.len(), CAP);
        assert_eq!(entries[0].text, "entry 504");
    }

    #[test]
    fn totals_survive_cap() {
        let dir = std::env::temp_dir().join(format!("ekonami-test-{}", Uuid::new_v4()));
        let store = HistoryStore::load(dir.join("history.json"));
        for _ in 0..600 {
            store.record(entry("uma duas três"));
        }
        let (words, _) = store.totals();
        assert_eq!(words, 600 * 3);
    }
}
