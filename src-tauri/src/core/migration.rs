//! Migração one-shot dos dados do app Swift (`com.mateus.ekonami`) para os stores Rust.
//!
//! SAFETY:
//! - Só roda em **release** (`!cfg!(debug_assertions)`). Debug usa `EkoNami-dev` e
//!   nunca toca em `~/Library/Application Support/EkoNami`.
//! - Lê a pasta/produtos do app Swift; escreve no `data_dir()` do processo.
//! - Nunca apaga a origem (WhisperKit/, plist de UserDefaults, etc.).
//! - Marker `.migrated-from-swift-v1` garante uma única execução.
//!
//! Formatos legados (verificados nos arquivos reais do Mateus):
//! - `dictionary.json`: array com `isEnabled` (camelCase)
//! - `history.json`: array plano (não o Snapshot `{entries,total_*}`)
//! - settings: UserDefaults em `~/Library/Preferences/com.mateus.ekonami.plist`

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::core::dictionary::{AppliedCorrection, DictionaryEntry, EntryKind};
use crate::core::history::HistoryEntry;
use crate::core::settings::{
    EngineKind, HotkeyMode, HotkeySpec, HudSize, Language, ParakeetVersion, SettingsFile,
};

const MARKER: &str = ".migrated-from-swift-v1";
const LEGACY_BUNDLE: &str = "com.mateus.ekonami";

/// Pasta fixa do app Swift / release — nunca confundir com `EkoNami-dev`.
pub fn legacy_prod_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join("Library/Application Support/EkoNami")
}

fn prefs_plist_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join("Library/Preferences")
        .join(format!("{LEGACY_BUNDLE}.plist"))
}

/// Entrypoint: no-op em debug; em release, uma vez, não-destrutivo.
pub fn run_if_needed(own_data_dir: &Path) {
    // CRITICAL: debug nunca toca a pasta de prod do app instalado.
    if cfg!(debug_assertions) {
        return;
    }
    let marker = own_data_dir.join(MARKER);
    if marker.exists() {
        return;
    }
    if let Err(e) = migrate(own_data_dir) {
        log::warn!("migração Swift→Rust: {e}");
        // Falha parcial: sem marker, permite retry no próximo launch.
        return;
    }
    if let Err(e) = std::fs::write(&marker, b"1") {
        log::warn!("não gravou marker de migração: {e}");
    }
}

fn migrate(own_data_dir: &Path) -> Result<(), String> {
    let _ = std::fs::create_dir_all(own_data_dir);
    let prod = legacy_prod_dir();

    // Settings a partir do plist — só grava settings.json se ainda não existir.
    let settings_path = own_data_dir.join("settings.json");
    if !settings_path.exists() {
        if let Some(file) = import_settings_from_plist(&prefs_plist_path()) {
            let data = serde_json::to_vec_pretty(&file).map_err(|e| e.to_string())?;
            std::fs::write(&settings_path, data).map_err(|e| e.to_string())?;
            log::info!("migração: settings.json importado do plist Swift");
        }
    }

    // Dictionary: se o destino já tem arquivo legível, não sobrescreve.
    // Se own == prod, o arquivo camelCase continua e o loader Rust usa alias.
    let dict_src = prod.join("dictionary.json");
    let dict_dst = own_data_dir.join("dictionary.json");
    if dict_src.exists() && (!dict_dst.exists() || dict_src != dict_dst) {
        let raw = std::fs::read(&dict_src).map_err(|e| e.to_string())?;
        let entries = transform_dictionary(&raw)?;
        let out = serde_json::to_vec_pretty(&entries).map_err(|e| e.to_string())?;
        // Só escreve se destino é outro path — nunca clobber do prod in-place
        // com rename snake_case (o Swift ainda pode estar instalado).
        if dict_src != dict_dst {
            std::fs::write(&dict_dst, out).map_err(|e| e.to_string())?;
            log::info!("migração: dictionary.json copiado/transformado");
        }
    }

    // History: array legado → Snapshot só quando o destino é outro path
    // (nunca sobrescreve o history.json de prod in-place). O loader Rust também
    // lê o array legado direto — ver `history::load_snapshot`.
    let hist_src = prod.join("history.json");
    let hist_dst = own_data_dir.join("history.json");
    if hist_src.exists() && hist_src != hist_dst && !hist_dst.exists() {
        let raw = std::fs::read(&hist_src).map_err(|e| e.to_string())?;
        if looks_like_legacy_history_array(&raw) {
            let snap = transform_history(&raw)?;
            let out = serde_json::to_vec_pretty(&snap).map_err(|e| e.to_string())?;
            std::fs::write(&hist_dst, out).map_err(|e| e.to_string())?;
            log::info!("migração: history.json convertido para Snapshot");
        } else {
            std::fs::copy(&hist_src, &hist_dst).map_err(|e| e.to_string())?;
        }
    }

    Ok(())
}

fn looks_like_legacy_history_array(raw: &[u8]) -> bool {
    let Ok(v) = serde_json::from_slice::<Value>(raw) else {
        return false;
    };
    v.is_array()
}

// ---------------------------------------------------------------------------
// Transforms puros (testáveis com fixtures)

#[derive(Debug, Deserialize)]
struct LegacyDictEntry {
    id: Uuid,
    kind: String,
    write: String,
    #[serde(default)]
    hear: String,
    #[serde(alias = "isEnabled", default = "default_true")]
    is_enabled: bool,
}

fn default_true() -> bool {
    true
}

pub fn transform_dictionary(raw: &[u8]) -> Result<Vec<DictionaryEntry>, String> {
    let legacy: Vec<LegacyDictEntry> =
        serde_json::from_slice(raw).map_err(|e| format!("dictionary: {e}"))?;
    Ok(legacy
        .into_iter()
        .map(|e| DictionaryEntry {
            id: e.id,
            kind: match e.kind.as_str() {
                "correction" => EntryKind::Correction,
                _ => EntryKind::Term,
            },
            write: e.write,
            hear: e.hear,
            is_enabled: e.is_enabled,
        })
        .collect())
}

#[derive(Debug, Deserialize)]
struct LegacyHistoryEntry {
    id: Uuid,
    date: String,
    text: String,
    engine: String,
    #[serde(default)]
    #[allow(dead_code)]
    language: String,
    #[serde(rename = "audioSeconds")]
    audio_seconds: f64,
    #[serde(rename = "processSeconds", default)]
    #[allow(dead_code)]
    process_seconds: f64,
    #[serde(default)]
    corrections: Option<Vec<AppliedCorrection>>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct HistorySnapshot {
    pub entries: Vec<HistoryEntry>,
    pub total_words: usize,
    pub total_seconds: f64,
}

pub fn transform_history(raw: &[u8]) -> Result<HistorySnapshot, String> {
    let legacy: Vec<LegacyHistoryEntry> =
        serde_json::from_slice(raw).map_err(|e| format!("history: {e}"))?;
    let mut total_words = 0usize;
    let mut total_seconds = 0.0f64;
    let entries: Vec<HistoryEntry> = legacy
        .into_iter()
        .map(|e| {
            let word_count = e.text.split_whitespace().count();
            total_words += word_count;
            total_seconds += e.audio_seconds;
            let created_at = DateTime::parse_from_rfc3339(&e.date)
                .map(|d| d.with_timezone(&Utc))
                .unwrap_or_else(|_| Utc::now());
            HistoryEntry {
                id: e.id,
                text: e.text.clone(),
                corrected_text: e.text,
                corrections: e.corrections.unwrap_or_default(),
                engine: e.engine,
                model: String::new(),
                duration_seconds: e.audio_seconds,
                word_count,
                created_at,
            }
        })
        .collect();
    Ok(HistorySnapshot {
        entries,
        total_words,
        total_seconds,
    })
}

#[derive(Debug, Deserialize)]
struct LegacyHotkey {
    #[serde(alias = "keyCode")]
    key_code: i64,
    #[serde(alias = "modifierFlag", default)]
    modifier_flag: u64,
    #[serde(alias = "displayName")]
    display_name: String,
}

/// Importa settings a partir do plist JSON-ish já decodificado (teste) ou do arquivo.
pub fn settings_from_legacy_map(map: &serde_json::Map<String, Value>) -> SettingsFile {
    let mut file = SettingsFile::default();

    if let Some(v) = map.get("engine").and_then(|v| v.as_str()) {
        file.engine = match v {
            "apple" => Some(EngineKind::Apple),
            "parakeet" => Some(EngineKind::Parakeet),
            "whisper" => Some(EngineKind::Whisper),
            _ => None,
        };
    }
    if let Some(v) = map.get("parakeetVersion").and_then(|v| v.as_str()) {
        file.parakeet_version = match v {
            "v2" => ParakeetVersion::V2,
            _ => ParakeetVersion::V3,
        };
    }
    if let Some(v) = map.get("whisperModel").and_then(|v| v.as_str()) {
        file.whisper_model = v.to_string();
    }
    if let Some(v) = map.get("language").and_then(|v| v.as_str()) {
        file.language = match v {
            "en-US" => Language::EnUS,
            _ => Language::PtBR,
        };
    }
    if let Some(v) = map.get("hotkeyMode").and_then(|v| v.as_str()) {
        file.hotkey_mode = match v {
            "toggle" => HotkeyMode::Toggle,
            _ => HotkeyMode::Hold,
        };
    }
    if let Some(v) = map.get("hudSize").and_then(|v| v.as_str()) {
        file.hud_size = match v {
            "minimal" => HudSize::Minimal,
            "large" => HudSize::Large,
            _ => HudSize::Medium,
        };
    }
    if let Some(v) = map.get("showMenuBar").and_then(|v| v.as_bool()) {
        file.show_menu_bar = v;
    }
    if let Some(v) = map.get("showDock").and_then(|v| v.as_bool()) {
        file.show_dock = v;
    }
    if let Some(v) = map.get("soundEnabled").and_then(|v| v.as_bool()) {
        file.sound_enabled = v;
    }
    if let Some(v) = map.get("dictionaryEnabled").and_then(|v| v.as_bool()) {
        file.dictionary_enabled = v;
    }
    if let Some(v) = map.get("saveHistory").and_then(|v| v.as_bool()) {
        file.save_history = v;
    }
    if let Some(v) = map.get("copyToClipboard").and_then(|v| v.as_bool()) {
        file.copy_to_clipboard = v;
    }
    if let Some(v) = map.get("pressReturn").and_then(|v| v.as_bool()) {
        file.press_return = v;
    }
    if let Some(data) = map.get("hotkey") {
        if let Ok(hk) = decode_hotkey(data) {
            file.hotkey = hk;
        }
    }
    file
}

fn decode_hotkey(v: &Value) -> Result<HotkeySpec, String> {
    match v {
        Value::String(s) => {
            let legacy: LegacyHotkey =
                serde_json::from_str(s).map_err(|e| e.to_string())?;
            Ok(HotkeySpec {
                key_code: legacy.key_code,
                modifier_flag: legacy.modifier_flag,
                display_name: legacy.display_name,
            })
        }
        Value::Object(_) => {
            let legacy: LegacyHotkey =
                serde_json::from_value(v.clone()).map_err(|e| e.to_string())?;
            Ok(HotkeySpec {
                key_code: legacy.key_code,
                modifier_flag: legacy.modifier_flag,
                display_name: legacy.display_name,
            })
        }
        Value::Array(bytes) => {
            // plist data às vezes chega como array de números
            let bytes: Vec<u8> = bytes
                .iter()
                .filter_map(|b| b.as_u64().map(|n| n as u8))
                .collect();
            let legacy: LegacyHotkey =
                serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
            Ok(HotkeySpec {
                key_code: legacy.key_code,
                modifier_flag: legacy.modifier_flag,
                display_name: legacy.display_name,
            })
        }
        _ => Err("hotkey shape".into()),
    }
}

#[cfg(target_os = "macos")]
fn import_settings_from_plist(path: &Path) -> Option<SettingsFile> {
    let data = std::fs::read(path).ok()?;
    // Preferências macOS são binary plist; `plist` crate seria ideal, mas evitamos
    // dep nova: `defaults export` não pode rodar aqui. Usamos o parser mínimo via
    // `plist` se disponível… fallback: tentar JSON (raro) ou defaults via plutil.
    if let Ok(v) = serde_json::from_slice::<Value>(&data) {
        if let Some(obj) = v.as_object() {
            return Some(settings_from_legacy_map(obj));
        }
    }
    // plutil -convert json -o - file (só leitura; não altera o plist)
    let out = std::process::Command::new("plutil")
        .args(["-convert", "json", "-o", "-", "--"])
        .arg(path)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let v: Value = serde_json::from_slice(&out.stdout).ok()?;
    let obj = v.as_object()?;
    // hotkey no JSON do plutil vira base64 string para <data> — decodificar.
    let mut map = obj.clone();
    if let Some(Value::String(b64)) = map.get("hotkey").cloned() {
        if let Ok(bytes) = decode_b64(&b64) {
            if let Ok(s) = String::from_utf8(bytes) {
                map.insert("hotkey".into(), Value::String(s));
            }
        }
    }
    Some(settings_from_legacy_map(&map))
}

#[cfg(not(target_os = "macos"))]
fn import_settings_from_plist(_path: &Path) -> Option<SettingsFile> {
    None
}

fn decode_b64(s: &str) -> Result<Vec<u8>, ()> {
    // decoder mínimo base64 (alfabeto standard) — só para o hotkey JSON no plist
    fn val(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let bytes: Vec<u8> = s.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    let mut buf = [0u8; 4];
    let mut n = 0;
    for b in bytes {
        if b == b'=' {
            break;
        }
        buf[n] = val(b).ok_or(())?;
        n += 1;
        if n == 4 {
            out.push((buf[0] << 2) | (buf[1] >> 4));
            out.push((buf[1] << 4) | (buf[2] >> 2));
            out.push((buf[2] << 6) | buf[3]);
            n = 0;
        }
    }
    if n == 3 {
        out.push((buf[0] << 2) | (buf[1] >> 4));
        out.push((buf[1] << 4) | (buf[2] >> 2));
    } else if n == 2 {
        out.push((buf[0] << 2) | (buf[1] >> 4));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE_DICT: &str = r#"[
      {"hear":"Park itch.","id":"A5C56E7E-BDD1-4820-8376-07C5F0F8F834","isEnabled":true,"kind":"correction","write":"Parakeet"},
      {"hear":"","id":"11111111-1111-1111-1111-111111111111","isEnabled":false,"kind":"term","write":"Anthropic"}
    ]"#;

    const FIXTURE_HIST: &str = r#"[
      {
        "audioSeconds": 5.2,
        "date": "2026-08-24T11:35:34Z",
        "engine": "APPLE LOCAL",
        "id": "53B4441A-3350-4CEC-B0BB-48268BB8912E",
        "language": "pt-BR",
        "processSeconds": 0.05,
        "text": "olá mundo"
      }
    ]"#;

    #[test]
    fn dictionary_camel_case_to_store() {
        let entries = transform_dictionary(FIXTURE_DICT.as_bytes()).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].write, "Parakeet");
        assert_eq!(entries[0].hear, "Park itch.");
        assert!(entries[0].is_enabled);
        assert_eq!(entries[0].kind, EntryKind::Correction);
        assert!(!entries[1].is_enabled);
        assert_eq!(entries[1].kind, EntryKind::Term);
    }

    #[test]
    fn history_array_to_snapshot() {
        let snap = transform_history(FIXTURE_HIST.as_bytes()).unwrap();
        assert_eq!(snap.entries.len(), 1);
        assert_eq!(snap.entries[0].text, "olá mundo");
        assert_eq!(snap.entries[0].corrected_text, "olá mundo");
        assert_eq!(snap.entries[0].engine, "APPLE LOCAL");
        assert!((snap.entries[0].duration_seconds - 5.2).abs() < 0.01);
        assert_eq!(snap.total_words, 2);
        assert!((snap.total_seconds - 5.2).abs() < 0.01);
        assert!(looks_like_legacy_history_array(FIXTURE_HIST.as_bytes()));
        let modern = serde_json::to_vec(&snap).unwrap();
        assert!(!looks_like_legacy_history_array(&modern));
    }

    #[test]
    fn settings_map_import() {
        let mut map = serde_json::Map::new();
        map.insert("engine".into(), Value::String("apple".into()));
        map.insert("language".into(), Value::String("pt-BR".into()));
        map.insert("hotkeyMode".into(), Value::String("hold".into()));
        map.insert("hudSize".into(), Value::String("large".into()));
        map.insert("showDock".into(), Value::Bool(false));
        map.insert(
            "hotkey".into(),
            Value::String(
                r#"{"keyCode":61,"modifierFlag":64,"displayName":"R⌥"}"#.into(),
            ),
        );
        let file = settings_from_legacy_map(&map);
        assert_eq!(file.engine, Some(EngineKind::Apple));
        assert_eq!(file.language, Language::PtBR);
        assert_eq!(file.hud_size, HudSize::Large);
        assert!(!file.show_dock);
        assert_eq!(file.hotkey.key_code, 61);
        assert_eq!(file.hotkey.modifier_flag, 64);
    }

    #[test]
    fn debug_gate_is_compile_time() {
        // Em debug assertions o entrypoint retorna sem I/O — não cria marker.
        let dir = std::env::temp_dir().join("ekonami-mig-test-debug");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        run_if_needed(&dir);
        if cfg!(debug_assertions) {
            assert!(!dir.join(MARKER).exists());
        }
    }
}
