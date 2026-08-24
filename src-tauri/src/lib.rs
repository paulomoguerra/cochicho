#[cfg(target_os = "macos")]
pub mod apple_bridge;
mod core;
mod platform;

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State};

use crate::core::dictation::{Deps, DictationController, StatePayload};
use crate::core::dictionary::{DictionaryEntry, DictionaryStore};
use crate::core::history::{HistoryEntry, HistoryStore};
use crate::core::models::{self, ModelStatus};
use crate::core::settings::{
    EngineKind, HotkeyMode, HotkeySpec, HudSize, Language, ParakeetVersion, Settings, SettingsFile,
    TerminalPaste, TileConfig,
};
use crate::platform::{hotkey, inject::TextInjector};

struct AppState {
    settings: Arc<Settings>,
    dictionary: Arc<DictionaryStore>,
    history: Arc<HistoryStore>,
    controller: DictationController,
    hotkey: std::sync::Mutex<hotkey::HotkeyMonitor>,
}

// ---------------------------------------------------------------------------
// Comandos

#[tauri::command]
fn platform_info() -> String {
    #[cfg(target_os = "macos")]
    {
        format!(
            "macos — apple speech available: {}",
            apple_bridge::speech_available()
        )
    }
    #[cfg(target_os = "linux")]
    {
        "linux".to_string()
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        "unsupported".to_string()
    }
}

#[tauri::command]
async fn dictation_toggle(state: State<'_, AppState>) -> Result<(), String> {
    state.controller.toggle_from_ui();
    Ok(())
}

#[tauri::command]
async fn dictation_state(state: State<'_, AppState>) -> Result<StatePayload, String> {
    let phase = state.controller.phase().await;
    Ok(StatePayload {
        state: match phase {
            crate::core::dictation::Phase::Idle => "idle",
            crate::core::dictation::Phase::Starting => "starting",
            crate::core::dictation::Phase::Listening => "listening",
            crate::core::dictation::Phase::Finishing => "finishing",
            crate::core::dictation::Phase::Failed => "failed",
        },
        error: None,
    })
}

#[tauri::command]
fn settings_get(state: State<'_, AppState>) -> SettingsFile {
    state.settings.get()
}

/// Patch parcial de settings — só campos Some são aplicados.
#[derive(Debug, Default, Deserialize)]
pub struct SettingsPatch {
    pub engine: Option<Option<EngineKind>>,
    pub parakeet_version: Option<ParakeetVersion>,
    pub whisper_model: Option<String>,
    pub language: Option<Language>,
    pub hotkey_mode: Option<HotkeyMode>,
    pub hud_size: Option<HudSize>,
    pub hotkey: Option<HotkeySpec>,
    pub show_menu_bar: Option<bool>,
    pub show_dock: Option<bool>,
    pub sound_enabled: Option<bool>,
    pub dictionary_enabled: Option<bool>,
    pub save_history: Option<bool>,
    pub copy_to_clipboard: Option<bool>,
    pub press_return: Option<bool>,
    pub terminal_paste: Option<TerminalPaste>,
    pub tile_layout: Option<Vec<TileConfig>>,
    pub custom_tile_layout: Option<Vec<TileConfig>>,
    pub layout_source_is_custom: Option<bool>,
}

#[tauri::command]
fn settings_update(app: AppHandle, state: State<'_, AppState>, patch: SettingsPatch) -> Result<SettingsFile, String> {
    let hotkey_changed = patch.hotkey.is_some();
    let terminal_paste = patch.terminal_paste;

    let snapshot = state.settings.update(|file| {
        if let Some(v) = patch.engine {
            file.engine = v;
        }
        if let Some(v) = patch.parakeet_version {
            file.parakeet_version = v;
        }
        if let Some(v) = patch.whisper_model {
            file.whisper_model = v;
        }
        if let Some(v) = patch.language {
            file.language = v;
        }
        if let Some(v) = patch.hotkey_mode {
            file.hotkey_mode = v;
        }
        if let Some(v) = patch.hud_size {
            file.hud_size = v;
        }
        if let Some(v) = patch.hotkey {
            file.hotkey = v;
        }
        if let Some(v) = patch.show_menu_bar {
            file.show_menu_bar = v;
        }
        if let Some(v) = patch.show_dock {
            file.show_dock = v;
        }
        if let Some(v) = patch.sound_enabled {
            file.sound_enabled = v;
        }
        if let Some(v) = patch.dictionary_enabled {
            file.dictionary_enabled = v;
        }
        if let Some(v) = patch.save_history {
            file.save_history = v;
        }
        if let Some(v) = patch.copy_to_clipboard {
            file.copy_to_clipboard = v;
        }
        if let Some(v) = patch.press_return {
            file.press_return = v;
        }
        if let Some(v) = patch.terminal_paste {
            file.terminal_paste = v;
        }
        if let Some(v) = patch.tile_layout {
            file.tile_layout = v;
        }
        if let Some(v) = patch.custom_tile_layout {
            file.custom_tile_layout = v;
        }
        if let Some(v) = patch.layout_source_is_custom {
            file.layout_source_is_custom = v;
        }
    });

    if let Some(mode) = terminal_paste {
        state.controller.deps().injector.set_terminal_paste(mode);
    }
    if hotkey_changed {
        start_hotkey_monitor(&app, &state);
    }

    let _ = app.emit("settings:changed", &snapshot);
    Ok(snapshot)
}

#[tauri::command]
fn dictionary_list(state: State<'_, AppState>) -> Vec<DictionaryEntry> {
    state.dictionary.entries()
}

#[tauri::command]
fn dictionary_add(app: AppHandle, state: State<'_, AppState>, entry: DictionaryEntry) -> Result<(), String> {
    state.dictionary.add(entry);
    let _ = app.emit("dictionary:changed", ());
    Ok(())
}

#[tauri::command]
fn dictionary_update(app: AppHandle, state: State<'_, AppState>, entry: DictionaryEntry) -> Result<(), String> {
    state.dictionary.update(entry);
    let _ = app.emit("dictionary:changed", ());
    Ok(())
}

#[tauri::command]
fn dictionary_remove(app: AppHandle, state: State<'_, AppState>, id: String) -> Result<(), String> {
    let uuid = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    state.dictionary.remove(uuid);
    let _ = app.emit("dictionary:changed", ());
    Ok(())
}

#[tauri::command]
fn dictionary_toggle(app: AppHandle, state: State<'_, AppState>, id: String) -> Result<(), String> {
    let uuid = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    state.dictionary.toggle(uuid);
    let _ = app.emit("dictionary:changed", ());
    Ok(())
}

#[tauri::command]
fn dictionary_restore_defaults(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    state.dictionary.restore_defaults();
    let _ = app.emit("dictionary:changed", ());
    Ok(())
}

#[tauri::command]
fn history_list(state: State<'_, AppState>) -> Vec<HistoryEntry> {
    state.history.entries()
}

/// Totais de vida toda — sobrevivem ao cap de 500 e ao clear da lista.
#[derive(Clone, Serialize)]
struct HistoryTotals {
    total_words: usize,
    total_seconds: f64,
    entry_count: usize,
}

#[tauri::command]
fn history_totals(state: State<'_, AppState>) -> HistoryTotals {
    let (total_words, total_seconds) = state.history.totals();
    HistoryTotals {
        total_words,
        total_seconds,
        entry_count: state.history.entries().len(),
    }
}

#[tauri::command]
fn history_clear(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    state.history.clear();
    let _ = app.emit("history:changed", ());
    Ok(())
}

#[tauri::command]
fn model_catalog() -> Vec<ModelStatus> {
    models::catalog_status()
}

#[derive(Clone, Serialize)]
struct DownloadProgress {
    name: String,
    progress: f64,
}

#[tauri::command]
async fn model_download(app: AppHandle, engine: EngineKind, name: String) -> Result<(), String> {
    let info = models::find_model(engine, &name).ok_or("modelo desconhecido")?;
    let name = info.name.to_string();
    let app2 = app.clone();
    models::download_model(info, move |p| {
        let _ = app2.emit(
            "model:progress",
            DownloadProgress {
                name: name.clone(),
                progress: p,
            },
        );
    })
    .await?;
    let _ = app.emit(
        "model:progress",
        DownloadProgress {
            name: info.name.to_string(),
            progress: 1.0,
        },
    );
    Ok(())
}

#[tauri::command]
fn model_delete(engine: EngineKind, name: String) -> Result<(), String> {
    let info = models::find_model(engine, &name).ok_or("modelo desconhecido")?;
    models::delete_model(info)
}

/// Linux: true enquanto o usuário não escolheu a engine default (primeiro run).
#[tauri::command]
fn onboarding_needed(state: State<'_, AppState>) -> bool {
    state.settings.get().engine.is_none() && cfg!(target_os = "linux")
}

#[cfg(target_os = "macos")]
#[tauri::command]
fn permissions_status() -> crate::platform::permissions_macos::PermissionsStatus {
    crate::platform::permissions_macos::status()
}

#[cfg(target_os = "macos")]
#[tauri::command]
fn permissions_prompt_accessibility() -> bool {
    crate::platform::permissions_macos::prompt_accessibility()
}

#[cfg(target_os = "macos")]
#[tauri::command]
fn permissions_request_microphone() -> bool {
    crate::platform::permissions_macos::request_microphone()
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn permissions_status() -> serde_json::Value {
    serde_json::json!({ "accessibility": true, "microphone": "authorized" })
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn permissions_prompt_accessibility() -> bool {
    true
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn permissions_request_microphone() -> bool {
    true
}

// ---------------------------------------------------------------------------
// Setup

fn start_hotkey_monitor(app: &AppHandle, state: &State<'_, AppState>) {
    let spec = state.settings.get().hotkey;
    let controller = state.controller.clone();
    let on_press = Arc::new(move || controller.hotkey_pressed());
    let controller = state.controller.clone();
    let on_release = Arc::new(move || controller.hotkey_released());

    let mut monitor = state.hotkey.lock().unwrap();
    if let Err(e) = monitor.start(spec, on_press, on_release) {
        log::warn!("hotkey monitor: {e}");
        let _ = app.emit("hotkey:unavailable", e.to_string());
    }
}

pub fn run() {
    env_logger::init();

    tauri::Builder::default()
        .setup(|app| {
            let data_dir = models::data_dir();
            // Release only: importa dados do app Swift uma vez (nunca em EkoNami-dev).
            crate::core::migration::run_if_needed(&data_dir);

            let settings = Arc::new(Settings::load(data_dir.join("settings.json")));
            let dictionary = Arc::new(DictionaryStore::load(data_dir.join("dictionary.json")));
            let history = Arc::new(HistoryStore::load(data_dir.join("history.json")));

            let injector = Arc::new(TextInjector::new(settings.get().terminal_paste));
            let deps = Deps {
                app: app.handle().clone(),
                settings: settings.clone(),
                dictionary: dictionary.clone(),
                history: history.clone(),
                injector,
            };
            let controller = DictationController::new(deps);

            app.manage(AppState {
                settings,
                dictionary,
                history,
                controller,
                hotkey: std::sync::Mutex::new(hotkey::HotkeyMonitor::new()),
            });

            create_hud_window(app)?;

            let state: State<'_, AppState> = app.state();
            start_hotkey_monitor(app.handle(), &state);

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            platform_info,
            dictation_toggle,
            dictation_state,
            settings_get,
            settings_update,
            dictionary_list,
            dictionary_add,
            dictionary_update,
            dictionary_remove,
            dictionary_toggle,
            dictionary_restore_defaults,
            history_list,
            history_totals,
            history_clear,
            model_catalog,
            model_download,
            model_delete,
            onboarding_needed,
            permissions_status,
            permissions_prompt_accessibility,
            permissions_request_microphone,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Eko Nami");
}

/// HUD flutuante: transparente, sem decorações, sempre no topo, fora da taskbar.
/// No macOS, após o build aplicamos tweaks NSWindow (nonactivating + floating)
/// — port do comportamento de `HUDPanel` sem redesenhar a UI (M5).
fn create_hud_window(app: &tauri::App) -> Result<(), tauri::Error> {
    use tauri::{LogicalPosition, LogicalSize, WebviewUrl, WebviewWindowBuilder};

    let settings = app.state::<AppState>().settings.get();
    let (width, height) = settings.hud_size.panel_size();

    let mut builder = WebviewWindowBuilder::new(
        app,
        "hud",
        WebviewUrl::App("index.html?window=hud".into()),
    )
    .title("")
    .inner_size(width, height)
    .resizable(false)
    .decorations(false)
    .transparent(true)
    .shadow(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .visible(false)
    .focused(false);

    // Posição: centro horizontal, ~96–120px acima da borda inferior (como o Swift).
    if let Ok(Some(monitor)) = app.primary_monitor() {
        let screen = monitor.size();
        let scale = monitor.scale_factor();
        let logical_h = screen.height as f64 / scale;
        let logical_w = screen.width as f64 / scale;
        builder = builder.position(
            (logical_w - width) / 2.0,
            logical_h - height - 120.0,
        );
        let _ = (LogicalPosition::new(0.0, 0.0), LogicalSize::new(0.0, 0.0));
    }

    let window = builder.build()?;
    let _ = window.set_ignore_cursor_events(true);

    #[cfg(target_os = "macos")]
    crate::platform::hud_macos::apply_nonactivating_panel(&window);

    Ok(())
}
