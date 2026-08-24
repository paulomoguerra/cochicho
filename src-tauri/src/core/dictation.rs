//! Port de `DictationController.swift` — a máquina de estados do ditado.
//!
//! idle → starting → listening → finishing → idle (ou failed).
//! Hotkey hold: press começa, release termina. Toggle: press alterna.
//! Watchdog de 300s encerra sessões esquecidas.

use std::sync::Arc;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::Mutex;

use crate::core::audio::AudioCapture;
use crate::core::dictionary::DictionaryStore;
use crate::core::engine::{EngineAvailability, TranscriptChunk, TranscriptionEngine};
use crate::core::engine_parakeet::ParakeetEngine;
use crate::core::engine_whisper::WhisperEngine;
use crate::core::history::{HistoryEntry, HistoryStore};
use crate::core::settings::{EngineKind, HotkeyMode, Settings};
use crate::platform::inject::TextInjector;

const MAX_RECORDING_SECONDS: u64 = 300;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Idle,
    Starting,
    Listening,
    Finishing,
    Failed,
}

#[derive(Clone, Serialize)]
pub struct StatePayload {
    pub state: &'static str,
    pub error: Option<String>,
}

impl StatePayload {
    fn for_phase(phase: Phase, error: Option<String>) -> Self {
        let state = match phase {
            Phase::Idle => "idle",
            Phase::Starting => "starting",
            Phase::Listening => "listening",
            Phase::Finishing => "finishing",
            Phase::Failed => "failed",
        };
        Self { state, error }
    }
}

#[derive(Clone)]
pub struct Deps {
    pub app: AppHandle,
    pub settings: Arc<Settings>,
    pub dictionary: Arc<DictionaryStore>,
    pub history: Arc<HistoryStore>,
    pub injector: Arc<TextInjector>,
}

struct Inner {
    phase: Phase,
    error: Option<String>,
    engine: Option<Box<dyn TranscriptionEngine>>,
    capture: AudioCapture,
    transcript: String,
    started_at: Option<std::time::Instant>,
    chunk_task: Option<tokio::task::JoinHandle<()>>,
    feed_task: Option<tokio::task::JoinHandle<()>>,
    watchdog: Option<tokio::task::JoinHandle<()>>,
    hide_task: Option<tokio::task::JoinHandle<()>>,
}

pub struct DictationController {
    inner: Arc<Mutex<Inner>>,
    deps: Deps,
}

impl Clone for DictationController {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
            deps: self.deps.clone(),
        }
    }
}

impl DictationController {
    pub fn deps(&self) -> &Deps {
        &self.deps
    }

    pub fn new(deps: Deps) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                phase: Phase::Idle,
                error: None,
                engine: None,
                capture: AudioCapture::new(),
                transcript: String::new(),
                started_at: None,
                chunk_task: None,
                feed_task: None,
                watchdog: None,
                hide_task: None,
            })),
            deps,
        }
    }

    pub async fn phase(&self) -> Phase {
        self.inner.lock().await.phase
    }

    // MARK: - Entradas externas

    pub fn hotkey_pressed(&self) {
        let inner = self.inner.clone();
        let deps = self.deps.clone();
        tokio::spawn(async move {
            let (phase, mode) = {
                let guard = inner.lock().await;
                (guard.phase, deps.settings.get().hotkey_mode)
            };
            match mode {
                HotkeyMode::Toggle if phase != Phase::Idle => {
                    Self::end_with(inner, deps).await;
                }
                _ if phase == Phase::Idle => {
                    Self::begin_with(inner, deps).await;
                }
                _ => {}
            }
        });
    }

    pub fn hotkey_released(&self) {
        let inner = self.inner.clone();
        let deps = self.deps.clone();
        tokio::spawn(async move {
            let (phase, mode) = {
                let guard = inner.lock().await;
                (guard.phase, deps.settings.get().hotkey_mode)
            };
            if mode == HotkeyMode::Hold && phase == Phase::Listening {
                Self::end_with(inner, deps).await;
            }
        });
    }

    /// Botão REC do dashboard / clique no tray.
    pub fn toggle_from_ui(&self) {
        let inner = self.inner.clone();
        let deps = self.deps.clone();
        tokio::spawn(async move {
            let phase = inner.lock().await.phase;
            match phase {
                Phase::Idle => Self::begin_with(inner, deps).await,
                Phase::Starting | Phase::Listening => Self::end_with(inner, deps).await,
                Phase::Finishing => Self::cancel_with(inner, deps, true).await,
                Phase::Failed => Self::reset_to_idle(inner, deps).await,
            }
        });
    }

    // MARK: - Máquina de estados

    async fn begin_with(inner: Arc<Mutex<Inner>>, deps: Deps) {
        let settings = deps.settings.get();

        let Some(kind) = deps.settings.effective_engine() else {
            Self::fail_with(inner, deps, "Escolha uma engine no onboarding.".into()).await;
            return;
        };

        let mut engine: Box<dyn TranscriptionEngine> = match kind {
            EngineKind::Whisper => {
                Box::new(WhisperEngine::new(&settings.whisper_model, settings.language))
            }
            EngineKind::Parakeet => Box::new(ParakeetEngine::new(settings.parakeet_version)),
            EngineKind::Apple => {
                #[cfg(target_os = "macos")]
                {
                    Box::new(crate::core::engine_apple::AppleEngine::new(settings.language))
                }
                #[cfg(not(target_os = "macos"))]
                {
                    Self::fail_with(inner, deps, "Engine Apple só existe no macOS.".into()).await;
                    return;
                }
            }
        };

        match engine.availability() {
            EngineAvailability::Available => {}
            EngineAvailability::NeedsDownload => {
                Self::fail_with(inner, deps, "Baixe o modelo no card ENGINE.".into()).await;
                return;
            }
            EngineAvailability::Unavailable => {
                Self::fail_with(inner, deps, "Engine indisponível nesta máquina.".into()).await;
                return;
            }
        }

        {
            let mut guard = inner.lock().await;
            guard.phase = Phase::Starting;
            guard.error = None;
            guard.transcript.clear();
        }
        Self::emit_state(&deps, Phase::Starting, None).await;
        Self::show_hud(&deps);

        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TranscriptChunk>();
        let prompt = deps.dictionary.bias_phrases().join(", ");
        if let Err(e) = engine.start(&prompt, tx).await {
            Self::fail_with(inner, deps, e.to_string()).await;
            return;
        }

        // Consumidor de chunks da engine (live ou final).
        let chunk_inner = inner.clone();
        let chunk_deps = deps.clone();
        let chunk_task = tokio::spawn(async move {
            while let Some(chunk) = rx.recv().await {
                let mut guard = chunk_inner.lock().await;
                if chunk.is_final {
                    guard.transcript = chunk.text;
                } else {
                    if !guard.transcript.is_empty() {
                        guard.transcript.push(' ');
                    }
                    guard.transcript.push_str(&chunk.text);
                }
                let text = guard.transcript.clone();
                drop(guard);
                Self::emit_transcript(&chunk_deps, &text, chunk.is_final);
            }
        });

        // Áudio: chunks 16kHz mono → engine.feed; nível → UI.
        let (audio_tx, mut audio_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<f32>>();
        let app_for_level = deps.app.clone();
        let mut capture = AudioCapture::new();
        let capture_result = capture.start(
            move |samples| {
                let _ = audio_tx.send(samples.to_vec());
            },
            move |level| {
                let _ = app_for_level.emit("audio:level", level);
            },
        );
        if let Err(e) = capture_result {
            chunk_task.abort();
            Self::fail_with(inner, deps, format!("Microfone: {e}")).await;
            return;
        }

        // Task que alimenta a engine com os chunks de áudio.
        let feed_inner = inner.clone();
        let feed_task = tokio::spawn(async move {
            while let Some(samples) = audio_rx.recv().await {
                let mut guard = feed_inner.lock().await;
                if let Some(engine) = guard.engine.as_mut() {
                    engine.feed(&samples);
                }
            }
        });

        {
            let mut guard = inner.lock().await;
            guard.engine = Some(engine);
            guard.capture = capture;
            guard.phase = Phase::Listening;
            guard.started_at = Some(std::time::Instant::now());
            guard.chunk_task = Some(chunk_task);
            guard.feed_task = Some(feed_task);
            guard.watchdog = Some(Self::spawn_watchdog(inner.clone(), deps.clone()));
        }

        Self::emit_state(&deps, Phase::Listening, None).await;
        Self::emit_transcript(&deps, "", false);
    }

    async fn end_with(inner: Arc<Mutex<Inner>>, deps: Deps) {
        let (mut engine, duration) = {
            let mut guard = inner.lock().await;
            if guard.phase != Phase::Listening && guard.phase != Phase::Starting {
                return;
            }
            guard.phase = Phase::Finishing;
            guard.capture.stop();
            if let Some(task) = guard.watchdog.take() {
                task.abort();
            }
            let duration = guard
                .started_at
                .map(|t| t.elapsed().as_secs_f64())
                .unwrap_or(0.0);
            let engine = guard.engine.take();
            (engine, duration)
        };
        Self::emit_state(&deps, Phase::Finishing, None).await;

        if let Some(engine) = engine.as_mut() {
            if let Err(e) = engine.finish().await {
                Self::fail_with(inner, deps, e.to_string()).await;
                return;
            }
        }

        // O chunk final pode estar na fila do consumer — dá um tick para ele processar.
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let transcript = {
            let guard = inner.lock().await;
            guard.transcript.trim().to_string()
        };

        if transcript.is_empty() {
            Self::reset_to_idle(inner, deps).await;
            return;
        }

        let settings = deps.settings.get();
        let (final_text, corrections) = if settings.dictionary_enabled {
            deps.dictionary.corrector().apply(&transcript)
        } else {
            (transcript.clone(), Vec::new())
        };

        if settings.save_history {
            deps.history.record(HistoryEntry {
                id: uuid::Uuid::new_v4(),
                text: transcript,
                corrected_text: final_text.clone(),
                corrections,
                engine: settings
                    .engine
                    .map(|e| format!("{e:?}").to_lowercase())
                    .unwrap_or_default(),
                model: match settings.engine {
                    Some(EngineKind::Parakeet) => settings.parakeet_version.model_name().to_string(),
                    _ => settings.whisper_model.clone(),
                },
                duration_seconds: duration,
                word_count: 0, // recalculado no store
                created_at: chrono::Utc::now(),
            });
            let _ = deps.app.emit("history:changed", ());
        }

        let injector = deps.injector.clone();
        let text_to_insert = final_text.clone();
        let press_return = settings.press_return;
        let copy_only = settings.copy_to_clipboard;
        tokio::task::spawn_blocking(move || {
            if copy_only {
                injector.copy_only(&text_to_insert)
            } else {
                injector.insert(&text_to_insert, press_return)
            }
        })
        .await
        .ok()
        .and_then(|r| r.err())
        .map(|e| log::warn!("injection failed: {e}"));

        Self::emit_transcript(&deps, &final_text, true);
        Self::reset_to_idle(inner, deps).await;
    }

    async fn cancel_with(inner: Arc<Mutex<Inner>>, deps: Deps, _from_ui: bool) {
        {
            let mut guard = inner.lock().await;
            guard.capture.stop();
            if let Some(task) = guard.watchdog.take() {
                task.abort();
            }
            if let Some(mut engine) = guard.engine.take() {
                tokio::spawn(async move {
                    engine.cancel().await;
                });
            }
            guard.transcript.clear();
        }
        Self::reset_to_idle(inner, deps).await;
    }

    async fn fail_with(inner: Arc<Mutex<Inner>>, deps: Deps, message: String) {
        log::warn!("dictation failed: {message}");
        {
            let mut guard = inner.lock().await;
            guard.phase = Phase::Failed;
            guard.error = Some(message.clone());
            guard.capture.stop();
            guard.engine = None;
        }
        Self::emit_state(&deps, Phase::Failed, Some(message)).await;

        // Erro fica visível um instante no HUD antes de voltar ao idle.
        let idle_inner = inner.clone();
        let idle_deps = deps.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(2500)).await;
            Self::reset_to_idle(idle_inner, idle_deps).await;
        });
    }

    async fn reset_to_idle(inner: Arc<Mutex<Inner>>, deps: Deps) {
        {
            let mut guard = inner.lock().await;
            guard.phase = Phase::Idle;
            guard.error = None;
            guard.engine = None;
            if let Some(task) = guard.chunk_task.take() {
                task.abort();
            }
            if let Some(task) = guard.feed_task.take() {
                task.abort();
            }
            if let Some(task) = guard.watchdog.take() {
                task.abort();
            }
        }
        Self::emit_state(&deps, Phase::Idle, None).await;

        // Limpa o transcript após 250ms (como o Swift) e esconde o HUD.
        let clear_inner = inner.clone();
        let clear_deps = deps.clone();
        let task = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            let mut guard = clear_inner.lock().await;
            if guard.phase == Phase::Idle {
                guard.transcript.clear();
                drop(guard);
                Self::emit_transcript(&clear_deps, "", true);
                if let Some(hud) = clear_deps.app.get_webview_window("hud") {
                    let _ = hud.hide();
                }
            }
        });
        inner.lock().await.hide_task = Some(task);
    }

    fn spawn_watchdog(inner: Arc<Mutex<Inner>>, deps: Deps) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(MAX_RECORDING_SECONDS)).await;
            let phase = inner.lock().await.phase;
            if phase == Phase::Listening {
                log::info!("watchdog: sessão passou de {MAX_RECORDING_SECONDS}s, encerrando");
                Self::end_with(inner, deps).await;
            }
        })
    }

    // MARK: - Eventos

    async fn emit_state(deps: &Deps, phase: Phase, error: Option<String>) {
        let _ = deps
            .app
            .emit("dictation:state", StatePayload::for_phase(phase, error));
    }

    fn emit_transcript(deps: &Deps, text: &str, is_final: bool) {
        #[derive(Clone, Serialize)]
        struct TranscriptPayload<'a> {
            text: &'a str,
            is_final: bool,
        }
        let _ = deps.app.emit(
            "dictation:transcript",
            TranscriptPayload { text, is_final },
        );
    }

    fn show_hud(deps: &Deps) {
        if let Some(hud) = deps.app.get_webview_window("hud") {
            let _ = hud.show();
        }
    }
}
