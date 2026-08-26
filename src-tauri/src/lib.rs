#[cfg(target_os = "macos")]
pub mod apple_bridge;
mod core;
mod platform;

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tauri::image::Image;
use tauri::menu::{
    CheckMenuItem, CheckMenuItemBuilder, MenuBuilder, MenuItem, MenuItemBuilder, SubmenuBuilder,
};
use tauri::tray::{TrayIcon, TrayIconBuilder};
use tauri::{AppHandle, Emitter, Manager, State};

use crate::core::dictation::{Deps, DictationController, StatePayload};
use crate::core::dictionary::{DictionaryEntry, DictionaryStore};
use crate::core::history::{HistoryEntry, HistoryStore};
use crate::core::models::{self, ModelStatus};
use crate::core::settings::{
    Appearance, EngineKind, HotkeyMode, HotkeySpec, HudSize, Language, ParakeetVersion, Settings,
    SettingsFile, TerminalPaste, TileConfig,
};
use crate::platform::{hotkey, inject::TextInjector};

struct AppState {
    settings: Arc<Settings>,
    dictionary: Arc<DictionaryStore>,
    history: Arc<HistoryStore>,
    controller: DictationController,
    hotkey: std::sync::Mutex<hotkey::HotkeyMonitor>,
    hotkey_error: std::sync::Mutex<Option<String>>,
    tray: std::sync::Mutex<Option<TrayState>>,
}

struct TrayState {
    icon: TrayIcon<tauri::Wry>,
    toggle: MenuItem<tauri::Wry>,
    apple: CheckMenuItem<tauri::Wry>,
    parakeet: CheckMenuItem<tauri::Wry>,
    whisper: CheckMenuItem<tauri::Wry>,
    portuguese: CheckMenuItem<tauri::Wry>,
    english: CheckMenuItem<tauri::Wry>,
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
    #[cfg(target_os = "macos")]
    if state.controller.phase().await == crate::core::dictation::Phase::Idle {
        use crate::platform::permissions_macos::MicStatus;
        let status = crate::platform::permissions_macos::microphone_status();
        if status != MicStatus::Authorized {
            let authorized = tokio::task::spawn_blocking(|| {
                crate::platform::permissions_macos::request_microphone()
            })
            .await
            .map_err(|e| e.to_string())?;
            if !authorized {
                return Err(
                    "Autorize o Microfone em Ajustes do Sistema → Privacidade e Segurança.".into(),
                );
            }
        }
    }
    state.controller.toggle_from_ui();
    Ok(())
}

#[tauri::command]
async fn dictation_state(state: State<'_, AppState>) -> Result<StatePayload, String> {
    let (phase, error, transcript) = state.controller.snapshot().await;
    Ok(StatePayload {
        state: match phase {
            crate::core::dictation::Phase::Idle => "idle",
            crate::core::dictation::Phase::Starting => "starting",
            crate::core::dictation::Phase::Listening => "listening",
            crate::core::dictation::Phase::Finishing => "finishing",
            crate::core::dictation::Phase::Failed => "failed",
        },
        error,
        transcript,
    })
}

#[tauri::command]
fn settings_get(state: State<'_, AppState>) -> SettingsFile {
    state.settings.get()
}

#[tauri::command]
fn hotkey_status(state: State<'_, AppState>) -> Option<String> {
    state
        .hotkey_error
        .lock()
        .ok()
        .and_then(|error| error.clone())
}

#[tauri::command]
async fn hotkey_capture_begin(state: State<'_, AppState>) -> Result<HotkeySpec, String> {
    {
        let mut monitor = state.hotkey.lock().map_err(|e| e.to_string())?;
        monitor.stop();
    }
    #[cfg(target_os = "macos")]
    {
        let (key_code, modifier_flag, display_name) =
            tokio::task::spawn_blocking(crate::apple_bridge::capture_hotkey)
                .await
                .map_err(|e| e.to_string())??;
        Ok(HotkeySpec {
            key_code,
            modifier_flag,
            display_name,
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("captura nativa disponível apenas no macOS".into())
    }
}

#[tauri::command]
fn hotkey_capture_cancel(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    crate::apple_bridge::cancel_hotkey_capture();
    start_hotkey_monitor(&app, &state);
    Ok(())
}

#[tauri::command]
fn hotkey_restart(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    start_hotkey_monitor(&app, &state);
    match state.hotkey_error.lock() {
        Ok(error) => error.clone().map_or(Ok(()), Err),
        Err(error) => Err(error.to_string()),
    }
}

/// Patch parcial de settings — só campos Some são aplicados.
#[derive(Debug, Default, Deserialize)]
pub struct SettingsPatch {
    pub engine: Option<Option<EngineKind>>,
    pub parakeet_version: Option<ParakeetVersion>,
    pub parakeet_model: Option<String>,
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
    pub appearance: Option<Appearance>,
}

#[tauri::command]
fn settings_update(
    app: AppHandle,
    state: State<'_, AppState>,
    patch: SettingsPatch,
) -> Result<SettingsFile, String> {
    let hotkey_changed = patch.hotkey.is_some();
    let hud_size_changed = patch.hud_size.is_some();
    let terminal_paste = patch.terminal_paste;

    let snapshot = state.settings.update(|file| {
        if let Some(v) = patch.engine {
            file.engine = v;
        }
        if let Some(v) = patch.parakeet_version {
            file.parakeet_version = v;
            if patch.parakeet_model.is_none() {
                file.parakeet_model = v.model_name().into();
            }
        }
        if let Some(v) = patch.parakeet_model {
            file.parakeet_model = v.clone();
            file.parakeet_version = ParakeetVersion::from_model_name(&v);
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
        // O status item é parte persistente do app e não pode mais ser desligado.
        file.show_menu_bar = true;
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
        if let Some(v) = patch.appearance {
            file.appearance = v;
        }
    });

    if let Some(mode) = terminal_paste {
        state.controller.deps().injector.set_terminal_paste(mode);
    }
    if hotkey_changed {
        start_hotkey_monitor(&app, &state);
    }
    if hud_size_changed {
        apply_hud_size(&app, snapshot.hud_size);
    }

    apply_window_appearance(&app, snapshot.appearance);
    sync_tray_menu(&app);

    let _ = app.emit("settings:changed", &snapshot);
    Ok(snapshot)
}

#[tauri::command]
fn dictionary_list(state: State<'_, AppState>) -> Vec<DictionaryEntry> {
    state.dictionary.entries()
}

#[tauri::command]
fn dictionary_add(
    app: AppHandle,
    state: State<'_, AppState>,
    entry: DictionaryEntry,
) -> Result<(), String> {
    state.dictionary.add(entry);
    let _ = app.emit("dictionary:changed", ());
    Ok(())
}

#[tauri::command]
fn dictionary_update(
    app: AppHandle,
    state: State<'_, AppState>,
    entry: DictionaryEntry,
) -> Result<(), String> {
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
struct ModelResidenceStatus {
    supported: bool,
    loaded_engine: Option<EngineKind>,
    loaded_model: Option<String>,
}

fn model_residence_snapshot() -> ModelResidenceStatus {
    if let Some(model) = crate::core::engine_apple::loaded_model() {
        return ModelResidenceStatus {
            supported: true,
            loaded_engine: Some(EngineKind::Apple),
            loaded_model: Some(model),
        };
    }
    if let Some(model) = crate::core::engine_whisper::loaded_model() {
        return ModelResidenceStatus {
            supported: true,
            loaded_engine: Some(EngineKind::Whisper),
            loaded_model: Some(model),
        };
    }
    if let Some(model) = crate::core::engine_parakeet::loaded_model() {
        return ModelResidenceStatus {
            supported: true,
            loaded_engine: Some(EngineKind::Parakeet),
            loaded_model: Some(model),
        };
    }
    ModelResidenceStatus {
        supported: true,
        loaded_engine: None,
        loaded_model: None,
    }
}

#[tauri::command]
fn model_residence(state: State<'_, AppState>) -> ModelResidenceStatus {
    let _ = state;
    model_residence_snapshot()
}

#[tauri::command]
async fn model_load_selected(state: State<'_, AppState>) -> Result<ModelResidenceStatus, String> {
    if state.controller.phase().await != crate::core::dictation::Phase::Idle {
        return Err("Encerre a gravação antes de carregar o modelo.".into());
    }
    let settings = state.settings.get();
    let engine = state
        .settings
        .effective_engine()
        .ok_or("Escolha uma engine primeiro.")?;

    match engine {
        EngineKind::Apple => {
            crate::core::engine_whisper::unload_model();
            crate::core::engine_parakeet::unload_model();
            let language = settings.language;
            tokio::task::spawn_blocking(move || crate::core::engine_apple::load_model(language))
                .await
                .map_err(|e| e.to_string())?
                .map_err(|e| e.to_string())?;
        }
        EngineKind::Whisper => {
            crate::core::engine_apple::unload_model();
            crate::core::engine_parakeet::unload_model();
            let model = settings.whisper_model;
            tokio::task::spawn_blocking(move || crate::core::engine_whisper::load_model(&model))
                .await
                .map_err(|e| e.to_string())?
                .map_err(|e| e.to_string())?;
        }
        EngineKind::Parakeet => {
            crate::core::engine_apple::unload_model();
            crate::core::engine_whisper::unload_model();
            let model = settings.parakeet_model;
            tokio::task::spawn_blocking(move || crate::core::engine_parakeet::load_model(&model))
                .await
                .map_err(|e| e.to_string())?
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(model_residence_snapshot())
}

#[tauri::command]
async fn model_unload(state: State<'_, AppState>) -> Result<ModelResidenceStatus, String> {
    if state.controller.phase().await != crate::core::dictation::Phase::Idle {
        return Err("Encerre a gravação antes de descarregar o modelo.".into());
    }
    tokio::task::spawn_blocking(|| {
        crate::core::engine_apple::unload_model();
        crate::core::engine_whisper::unload_model();
        crate::core::engine_parakeet::unload_model();
    })
    .await
    .map_err(|e| e.to_string())?;
    Ok(model_residence_snapshot())
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
    if crate::core::engine_whisper::loaded_model().as_deref() == Some(&name) {
        crate::core::engine_whisper::unload_model();
    }
    if crate::core::engine_parakeet::loaded_model().as_deref() == Some(&name) {
        crate::core::engine_parakeet::unload_model();
    }
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

#[cfg(target_os = "macos")]
#[tauri::command]
fn permissions_open_settings(kind: String) -> bool {
    let anchor = match kind.as_str() {
        "microphone" => "Privacy_Microphone",
        "accessibility" => "Privacy_Accessibility",
        _ => return false,
    };
    std::process::Command::new("/usr/bin/open")
        .arg(format!(
            "x-apple.systempreferences:com.apple.preference.security?{anchor}"
        ))
        .status()
        .is_ok_and(|status| status.success())
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

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn permissions_open_settings(_kind: String) -> bool {
    true
}

// ---------------------------------------------------------------------------
// Setup

fn apply_window_appearance(app: &AppHandle, appearance: Appearance) {
    use tauri::window::Color;
    use tauri::Theme;
    let (theme, color) = match appearance {
        Appearance::Dark => (Theme::Dark, Color(0x13, 0x12, 0x11, 255)),
        Appearance::Light => (Theme::Light, Color(0xed, 0xe8, 0xe0, 255)),
    };
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_theme(Some(theme));
        let _ = win.set_background_color(Some(color));
    }
    if let Some(win) = app.get_webview_window("hud") {
        let _ = win.set_theme(Some(theme));
    }
}

fn apply_hud_size(app: &AppHandle, hud_size: HudSize) {
    use tauri::{LogicalPosition, LogicalSize};
    let Some(hud) = app.get_webview_window("hud") else {
        return;
    };
    let (width, height) = hud_size.panel_size();
    let _ = hud.set_size(LogicalSize::new(width, height));
    if let Ok(Some(monitor)) = app.primary_monitor() {
        let screen = monitor.size();
        let scale = monitor.scale_factor();
        let logical_h = screen.height as f64 / scale;
        let logical_w = screen.width as f64 / scale;
        let _ = hud.set_position(LogicalPosition::new(
            (logical_w - width) / 2.0,
            logical_h - height - 120.0,
        ));
    }
}

fn setup_tray(app: &tauri::App) -> Result<(), tauri::Error> {
    let state: State<'_, AppState> = app.state();
    let settings = state.settings.get();
    let engine = state.settings.effective_engine();

    let toggle = MenuItemBuilder::with_id("tray-toggle", "Iniciar ditado").build(app)?;
    let apple = CheckMenuItemBuilder::with_id("tray-engine-apple", "Apple")
        .checked(engine == Some(EngineKind::Apple))
        .build(app)?;
    let parakeet = CheckMenuItemBuilder::with_id("tray-engine-parakeet", "Parakeet")
        .checked(engine == Some(EngineKind::Parakeet))
        .build(app)?;
    let whisper = CheckMenuItemBuilder::with_id("tray-engine-whisper", "Whisper")
        .checked(engine == Some(EngineKind::Whisper))
        .build(app)?;
    let portuguese = CheckMenuItemBuilder::with_id("tray-language-pt", "Português (Brasil)")
        .checked(settings.language == Language::PtBR)
        .build(app)?;
    let english = CheckMenuItemBuilder::with_id("tray-language-en", "English (US)")
        .checked(settings.language == Language::EnUS)
        .build(app)?;

    let engine_menu = SubmenuBuilder::new(app, "Engine")
        .items(&[&apple, &parakeet, &whisper])
        .build()?;
    let language_menu = SubmenuBuilder::new(app, "Idioma")
        .items(&[&portuguese, &english])
        .build()?;
    let open = MenuItemBuilder::with_id("tray-open", "Abrir Eko Nami").build(app)?;
    let quit = MenuItemBuilder::with_id("tray-quit", "Sair")
        .accelerator("Cmd+Q")
        .build(app)?;
    let menu = MenuBuilder::new(app)
        .item(&toggle)
        .separator()
        .item(&engine_menu)
        .item(&language_menu)
        .separator()
        .item(&open)
        .item(&quit)
        .build()?;

    let mut builder = TrayIconBuilder::with_id("ekonami-menubar")
        .menu(&menu)
        .tooltip("Eko Nami")
        .show_menu_on_left_click(true)
        .on_menu_event(handle_tray_menu_event);
    if let Some(icon) = tray_symbol(false) {
        builder = builder.icon(icon).icon_as_template(true);
    }
    let icon = builder.build(app)?;

    if let Ok(mut tray) = state.tray.lock() {
        *tray = Some(TrayState {
            icon,
            toggle,
            apple,
            parakeet,
            whisper,
            portuguese,
            english,
        });
    }
    Ok(())
}

fn handle_tray_menu_event(app: &AppHandle, event: tauri::menu::MenuEvent) {
    match event.id().as_ref() {
        "tray-toggle" => app.state::<AppState>().controller.toggle_from_ui(),
        "tray-engine-apple" => set_engine_from_tray(app, EngineKind::Apple),
        "tray-engine-parakeet" => set_engine_from_tray(app, EngineKind::Parakeet),
        "tray-engine-whisper" => set_engine_from_tray(app, EngineKind::Whisper),
        "tray-language-pt" => set_language_from_tray(app, Language::PtBR),
        "tray-language-en" => set_language_from_tray(app, Language::EnUS),
        "tray-open" => {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
            }
        }
        "tray-quit" => app.exit(0),
        _ => {}
    }
}

fn set_engine_from_tray(app: &AppHandle, engine: EngineKind) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let state: State<'_, AppState> = app.state();
        if state.controller.phase().await != crate::core::dictation::Phase::Idle {
            return;
        }
        crate::core::engine_whisper::unload_model();
        crate::core::engine_parakeet::unload_model();
        crate::core::engine_apple::unload_model();
        let snapshot = state
            .settings
            .update(|settings| settings.engine = Some(engine));
        sync_tray_menu(&app);
        let _ = app.emit("settings:changed", snapshot);
    });
}

fn set_language_from_tray(app: &AppHandle, language: Language) {
    let state: State<'_, AppState> = app.state();
    let snapshot = state
        .settings
        .update(|settings| settings.language = language);
    sync_tray_menu(app);
    let _ = app.emit("settings:changed", snapshot);
}

fn sync_tray_menu(app: &AppHandle) {
    let state: State<'_, AppState> = app.state();
    let settings = state.settings.get();
    let engine = state.settings.effective_engine();
    let Ok(tray) = state.tray.lock() else {
        return;
    };
    let Some(tray) = tray.as_ref() else {
        return;
    };
    let _ = tray.apple.set_checked(engine == Some(EngineKind::Apple));
    let _ = tray
        .parakeet
        .set_checked(engine == Some(EngineKind::Parakeet));
    let _ = tray
        .whisper
        .set_checked(engine == Some(EngineKind::Whisper));
    let _ = tray
        .portuguese
        .set_checked(settings.language == Language::PtBR);
    let _ = tray
        .english
        .set_checked(settings.language == Language::EnUS);
}

pub(crate) fn sync_tray_recording(app: &AppHandle, active: bool) {
    let state: State<'_, AppState> = app.state();
    let Ok(tray) = state.tray.lock() else {
        return;
    };
    if let Some(tray) = tray.as_ref() {
        let _ = tray.toggle.set_text(if active {
            "Parar ditado"
        } else {
            "Iniciar ditado"
        });
        if let Some(icon) = tray_symbol(active) {
            let _ = tray.icon.set_icon_with_as_template(Some(icon), true);
        }
    }
}

#[cfg(target_os = "macos")]
fn tray_symbol(active: bool) -> Option<Image<'static>> {
    crate::apple_bridge::menubar_icon_png(active).and_then(|bytes| Image::from_bytes(&bytes).ok())
}

#[cfg(not(target_os = "macos"))]
fn tray_symbol(_active: bool) -> Option<Image<'static>> {
    None
}

fn start_hotkey_monitor(app: &AppHandle, state: &State<'_, AppState>) {
    let spec = state.settings.get().hotkey;
    let controller = state.controller.clone();
    let on_press = Arc::new(move || controller.hotkey_pressed());
    let controller = state.controller.clone();
    let on_release = Arc::new(move || controller.hotkey_released());

    let mut monitor = state.hotkey.lock().unwrap();
    if let Err(e) = monitor.start(spec, on_press, on_release) {
        log::warn!("hotkey monitor: {e}");
        let message = e.to_string();
        if let Ok(mut error) = state.hotkey_error.lock() {
            *error = Some(message.clone());
        }
        let _ = app.emit("hotkey:unavailable", message);
    } else {
        if let Ok(mut error) = state.hotkey_error.lock() {
            *error = None;
        }
        let _ = app.emit("hotkey:available", ());
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
            if !settings.get().show_menu_bar {
                settings.update(|file| file.show_menu_bar = true);
            }
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
                hotkey_error: std::sync::Mutex::new(None),
                tray: std::sync::Mutex::new(None),
            });

            #[cfg(target_os = "macos")]
            if let Some(main) = app.get_webview_window("main") {
                crate::platform::window_macos::disable_state_restoration(&main);
            }

            create_hud_window(app)?;
            setup_tray(app)?;

            let state: State<'_, AppState> = app.state();
            start_hotkey_monitor(app.handle(), &state);
            apply_window_appearance(app.handle(), state.settings.get().appearance);

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            platform_info,
            dictation_toggle,
            dictation_state,
            settings_get,
            hotkey_status,
            hotkey_capture_begin,
            hotkey_capture_cancel,
            hotkey_restart,
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
            model_residence,
            model_load_selected,
            model_unload,
            model_download,
            model_delete,
            onboarding_needed,
            permissions_status,
            permissions_prompt_accessibility,
            permissions_request_microphone,
            permissions_open_settings,
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

    let mut builder =
        WebviewWindowBuilder::new(app, "hud", WebviewUrl::App("index.html?window=hud".into()))
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
        builder = builder.position((logical_w - width) / 2.0, logical_h - height - 120.0);
        let _ = (LogicalPosition::new(0.0, 0.0), LogicalSize::new(0.0, 0.0));
    }

    let window = builder.build()?;

    // No Linux a janela começa invisível e o GdkWindow só é realizado no primeiro
    // show(); chamar set_ignore_cursor_events antes disso faz o tao dar unwrap em
    // None dentro do dispatch do glib e aborta o processo. Por isso no Linux isso
    // acontece em DictationController::show_hud, após o show().
    #[cfg(target_os = "macos")]
    {
        crate::platform::window_macos::disable_state_restoration(&window);
        let _ = window.set_ignore_cursor_events(true);
        crate::platform::hud_macos::apply_nonactivating_panel(&window);
    }

    Ok(())
}
