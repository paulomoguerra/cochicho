//! Port de `Settings.swift` + `Bento.swift` (Tile/TileConfig) + `HotkeySpec.swift`.
//! Toda configuração vive num único `settings.json` no diretório de dados da plataforma.
//! Os nomes das chaves batem com os UserDefaults do app Swift para a migração (M4).

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::RwLock;

use serde::{Deserialize, Serialize};

use crate::core::persist::DiskPersister;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EngineKind {
    Apple,
    Parakeet,
    Whisper,
}

impl EngineKind {
    pub fn display_name(&self) -> &'static str {
        match self {
            EngineKind::Apple => "APPLE LOCAL",
            EngineKind::Parakeet => "PARAKEET",
            EngineKind::Whisper => "WHISPER",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ParakeetVersion {
    V3,
    V2,
}

impl ParakeetVersion {
    pub fn model_name(&self) -> &'static str {
        match self {
            ParakeetVersion::V3 => "parakeet-tdt-0.6b-v3",
            ParakeetVersion::V2 => "parakeet-tdt-0.6b-v2",
        }
    }

    pub fn from_model_name(name: &str) -> Self {
        if name.contains("v2") {
            ParakeetVersion::V2
        } else {
            ParakeetVersion::V3
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Appearance {
    #[default]
    Dark,
    Light,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Language {
    #[serde(rename = "pt-BR")]
    PtBR,
    #[serde(rename = "en-US")]
    EnUS,
}

impl Language {
    /// Código curto para engines (whisper.cpp usa "pt"/"en").
    pub fn whisper_code(&self) -> &'static str {
        match self {
            Language::PtBR => "pt",
            Language::EnUS => "en",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HotkeyMode {
    Hold,
    Toggle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HudSize {
    Minimal,
    Medium,
    Large,
}

impl HudSize {
    /// Tamanhos do painel — portados de `HUD.swift` (panelSize).
    pub fn panel_size(&self) -> (f64, f64) {
        match self {
            HudSize::Minimal => (220.0, 76.0),
            HudSize::Medium => (380.0, 156.0),
            HudSize::Large => (480.0, 210.0),
        }
    }
}

/// Tecla de atalho. No macOS: CGKeyCode + NX_DEVICE_* bits do modificador (0 = tecla
/// comum). No Linux: código evdev (KEY_*), modifier_flag sempre 0.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotkeySpec {
    pub key_code: i64,
    #[serde(default)]
    pub modifier_flag: u64,
    pub display_name: String,
}

impl HotkeySpec {
    #[cfg(target_os = "macos")]
    pub fn platform_default() -> Self {
        // R⌥ — mesmo default do app Swift.
        Self {
            key_code: 61,
            modifier_flag: 0x40,
            display_name: "R⌥".into(),
        }
    }

    #[cfg(target_os = "linux")]
    pub fn platform_default() -> Self {
        // KEY_RIGHTCTRL (evdev 97) — tecla quase nunca usada como atalho de app.
        Self {
            key_code: 97,
            modifier_flag: 0,
            display_name: "RCTRL".into(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tile {
    Mic,
    Engine,
    Stats,
    History,
    Dictionary,
    Controls,
}

impl Tile {
    pub fn title(&self) -> &'static str {
        match self {
            Tile::Mic => "MIC",
            Tile::Engine => "ENGINE",
            Tile::Stats => "STATS",
            Tile::History => "HISTORY",
            Tile::Dictionary => "DICTIONARY",
            Tile::Controls => "CONTROLS",
        }
    }
}

/// Tamanhos nomeados como no Trackpad: P/L/A/G.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum TileSize {
    #[serde(rename = "small")]
    Small, // 1×1
    #[serde(rename = "wide")]
    Wide, // 2×1
    #[serde(rename = "tall")]
    Tall, // 1×2
    #[serde(rename = "big")]
    Big, // 2×2
}

impl TileSize {
    pub fn columns(&self) -> u32 {
        match self {
            TileSize::Small | TileSize::Tall => 1,
            TileSize::Wide | TileSize::Big => 2,
        }
    }

    pub fn rows(&self) -> u32 {
        match self {
            TileSize::Small | TileSize::Wide => 1,
            TileSize::Tall | TileSize::Big => 2,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TileConfig {
    pub tile: Tile,
    pub size: TileSize,
}

impl TileConfig {
    /// Dashboard de fábrica — screenshot do Mateus de 2026-08-22.
    pub fn default_layout() -> [TileConfig; 6] {
        [
            TileConfig { tile: Tile::Mic, size: TileSize::Wide },
            TileConfig { tile: Tile::Engine, size: TileSize::Tall },
            TileConfig { tile: Tile::Stats, size: TileSize::Small },
            TileConfig { tile: Tile::History, size: TileSize::Big },
            TileConfig { tile: Tile::Controls, size: TileSize::Tall },
            TileConfig { tile: Tile::Dictionary, size: TileSize::Small },
        ]
    }

    /// Layout de fábrica pré-presets — só migração.
    pub fn legacy_default_layout() -> [TileConfig; 6] {
        [
            TileConfig { tile: Tile::Mic, size: TileSize::Wide },
            TileConfig { tile: Tile::Engine, size: TileSize::Tall },
            TileConfig { tile: Tile::Stats, size: TileSize::Small },
            TileConfig { tile: Tile::History, size: TileSize::Big },
            TileConfig { tile: Tile::Dictionary, size: TileSize::Tall },
            TileConfig { tile: Tile::Controls, size: TileSize::Tall },
        ]
    }

    /// Fábrica breve com mic-big entre legacy e atual — só comparação de migração.
    pub fn previous_default_layout() -> [TileConfig; 6] {
        [
            TileConfig { tile: Tile::Mic, size: TileSize::Big },
            TileConfig { tile: Tile::Engine, size: TileSize::Tall },
            TileConfig { tile: Tile::Controls, size: TileSize::Tall },
            TileConfig { tile: Tile::History, size: TileSize::Big },
            TileConfig { tile: Tile::Dictionary, size: TileSize::Tall },
            TileConfig { tile: Tile::Stats, size: TileSize::Small },
        ]
    }
}

/// Payload persistido em settings.json.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct SettingsFile {
    /// None = nunca escolheu. macOS resolve para Apple; Linux abre o picker de engine.
    pub engine: Option<EngineKind>,
    pub parakeet_version: ParakeetVersion,
    /// Nome canônico no catálogo Parakeet. Vazio no JSON antigo → preenchido no load.
    #[serde(default)]
    pub parakeet_model: String,
    /// Nome do modelo whisper (legado: "openai_whisper-base"; novo: "ggml-base.bin").
    pub whisper_model: String,
    pub language: Language,
    pub hotkey_mode: HotkeyMode,
    pub hud_size: HudSize,
    pub hotkey: HotkeySpec,
    pub show_menu_bar: bool,
    pub show_dock: bool,
    pub sound_enabled: bool,
    pub dictionary_enabled: bool,
    pub save_history: bool,
    pub copy_to_clipboard: bool,
    pub press_return: bool,
    /// Linux: colar com Ctrl+Shift+V (terminais) em vez de Ctrl+V. `auto` detecta pela
    /// classe da janela no X11; em Wayland puro cai no valor manual.
    #[serde(default)]
    pub terminal_paste: TerminalPaste,
    pub tile_layout: Vec<TileConfig>,
    pub custom_tile_layout: Vec<TileConfig>,
    pub layout_source_is_custom: bool,
    #[serde(default)]
    pub appearance: Appearance,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TerminalPaste {
    #[default]
    Auto,
    Always,
    Never,
}

impl Default for SettingsFile {
    fn default() -> Self {
        Self {
            engine: None,
            parakeet_version: ParakeetVersion::V3,
            parakeet_model: ParakeetVersion::V3.model_name().into(),
            whisper_model: "openai_whisper-base".into(),
            language: Language::PtBR,
            hotkey_mode: HotkeyMode::Hold,
            hud_size: HudSize::Medium,
            hotkey: HotkeySpec::platform_default(),
            show_menu_bar: true,
            show_dock: true,
            sound_enabled: true,
            dictionary_enabled: true,
            save_history: true,
            copy_to_clipboard: false,
            press_return: false,
            terminal_paste: TerminalPaste::Auto,
            tile_layout: TileConfig::default_layout().to_vec(),
            custom_tile_layout: Vec::new(),
            layout_source_is_custom: false,
            appearance: Appearance::Dark,
        }
    }
}

impl SettingsFile {
    /// Migração de preset legado (port de `sanitizePresets`): se o layout salvo é o
    /// default antigo byte-a-byte, regrava com o novo default.
    pub fn sanitize_presets(&mut self) {
        let current: Vec<TileConfig> = TileConfig::default_layout().to_vec();
        let legacy: Vec<TileConfig> = TileConfig::legacy_default_layout().to_vec();
        let previous: Vec<TileConfig> = TileConfig::previous_default_layout().to_vec();
        if !self.layout_source_is_custom
            && (self.tile_layout == legacy || self.tile_layout == previous)
        {
            self.tile_layout = current;
        }
    }

    pub fn active_layout(&self) -> &[TileConfig] {
        if self.layout_source_is_custom && !self.custom_tile_layout.is_empty() {
            &self.custom_tile_layout
        } else {
            &self.tile_layout
        }
    }
}

pub struct Settings {
    file: RwLock<SettingsFile>,
    persister: DiskPersister,
    save_version: AtomicU64,
}

impl Settings {
    pub fn load(path: PathBuf) -> Self {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let mut file: SettingsFile = std::fs::read(&path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default();
        file.sanitize_presets();
        if file.parakeet_model.trim().is_empty() {
            file.parakeet_model = file.parakeet_version.model_name().into();
        }

        Self {
            file: RwLock::new(file),
            persister: DiskPersister::new(path),
            save_version: AtomicU64::new(0),
        }
    }

    pub fn get(&self) -> SettingsFile {
        self.file.read().unwrap().clone()
    }

    /// Aplica uma mutação e persiste. Retorna o snapshot novo para o caller emitir.
    pub fn update(&self, mutate: impl FnOnce(&mut SettingsFile)) -> SettingsFile {
        {
            let mut file = self.file.write().unwrap();
            mutate(&mut file);
        }
        let snapshot = self.get();
        let version = self.save_version.fetch_add(1, Ordering::SeqCst) + 1;
        self.persister.save(snapshot.clone(), version);
        snapshot
    }

    /// Engine efetiva considerando o default de plataforma.
    /// No Linux pode continuar None — é o sinal para o onboarding de engine.
    pub fn effective_engine(&self) -> Option<EngineKind> {
        let chosen = self.file.read().unwrap().engine;
        #[cfg(target_os = "macos")]
        {
            Some(chosen.unwrap_or(EngineKind::Apple))
        }
        #[cfg(not(target_os = "macos"))]
        {
            chosen
        }
    }
}
