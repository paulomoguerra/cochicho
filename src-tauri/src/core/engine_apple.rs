//! Engine Apple via FFI do `apple-speech-bridge` (port de `AppleSpeechEngine.swift`).
//!
//! Threading: o callback C dispara na fila do Speech framework. Encaminhamos
//! direto para `ChunkTx` (`tokio::sync::mpsc::UnboundedSender`), que é Send e
//! aceita send de qualquer thread — sem canal intermediário.

use std::ffi::{c_char, c_void};
use std::sync::{Arc, Mutex};

use crate::apple_bridge::{self, ChunkCallback};
use crate::core::engine::{
    ChunkTx, EngineAvailability, EngineError, TranscriptChunk, TranscriptionEngine,
};
use crate::core::settings::Language;

struct CallbackState {
    tx: ChunkTx,
    last_error: Option<String>,
}

pub struct AppleEngine {
    locale: String,
    session: Option<i32>,
    /// Mantido vivo enquanto a sessão existe — o ponteiro vai no user_data do callback.
    cb_state: Option<Box<Arc<Mutex<CallbackState>>>>,
}

impl AppleEngine {
    pub fn new(language: Language) -> Self {
        let locale = match language {
            Language::PtBR => "pt-BR",
            Language::EnUS => "en-US",
        };
        Self {
            locale: locale.into(),
            session: None,
            cb_state: None,
        }
    }
}

/// kind: 0 partial, 1 final, 2 error, 3 ended
unsafe extern "C" fn on_chunk(user_data: *mut c_void, text: *const c_char, kind: i32) {
    if user_data.is_null() {
        return;
    }
    let state = &*(user_data as *const Arc<Mutex<CallbackState>>);
    let Ok(mut guard) = state.lock() else { return };

    match kind {
        0 | 1 => {
            let text = apple_bridge::text_from_callback(text);
            if text.is_empty() && kind == 0 {
                return;
            }
            let _ = guard.tx.send(TranscriptChunk {
                text,
                is_final: kind == 1,
            });
        }
        2 => {
            let err = apple_bridge::text_from_callback(text);
            guard.last_error = Some(if err.is_empty() {
                "apple speech error".into()
            } else {
                err
            });
        }
        _ => {} // 3 ended — finish/cancel cuidam do lifecycle
    }
}

#[async_trait::async_trait]
impl TranscriptionEngine for AppleEngine {
    async fn start(&mut self, prompt: &str, tx: ChunkTx) -> Result<(), EngineError> {
        if !apple_bridge::speech_available() {
            return Err(EngineError::Unavailable);
        }
        if apple_bridge::bridge_version() < 2 {
            return Err(EngineError::Failed(
                "apple-speech-bridge ABI < 2".into(),
            ));
        }

        let state = Arc::new(Mutex::new(CallbackState {
            tx,
            last_error: None,
        }));
        let boxed = Box::new(state);
        let user_data_addr =
            (&*boxed.as_ref()) as *const Arc<Mutex<CallbackState>> as usize;

        let locale = self.locale.clone();
        let bias = prompt.to_string();
        let cb: ChunkCallback = on_chunk;

        // session_start bloqueia até o analyzer subir (semaphore no Swift).
        let session = tokio::task::spawn_blocking(move || {
            apple_bridge::session_start(
                &locale,
                &bias,
                cb,
                user_data_addr as *mut c_void,
            )
        })
        .await
        .map_err(|e| EngineError::Failed(e.to_string()))?
        .map_err(EngineError::Failed)?;

        self.cb_state = Some(boxed);
        self.session = Some(session);
        Ok(())
    }

    fn feed(&mut self, samples: &[f32]) {
        let Some(session) = self.session else { return };
        if let Err(e) = apple_bridge::session_feed(session, samples) {
            log::warn!("apple feed: {e}");
        }
    }

    async fn finish(&mut self) -> Result<(), EngineError> {
        let Some(session) = self.session.take() else {
            return Ok(());
        };
        let result = tokio::task::spawn_blocking(move || apple_bridge::session_finish(session))
            .await
            .map_err(|e| EngineError::Failed(e.to_string()))?;

        let err = self
            .cb_state
            .as_ref()
            .and_then(|s| s.lock().ok())
            .and_then(|g| g.last_error.clone());
        self.cb_state = None;

        if let Some(err) = err {
            return Err(EngineError::Failed(err));
        }
        result.map_err(EngineError::Failed)
    }

    async fn cancel(&mut self) {
        if let Some(session) = self.session.take() {
            tokio::task::spawn_blocking(move || apple_bridge::session_cancel(session))
                .await
                .ok();
        }
        self.cb_state = None;
    }

    fn availability(&self) -> EngineAvailability {
        if apple_bridge::speech_available() {
            EngineAvailability::Available
        } else {
            EngineAvailability::Unavailable
        }
    }

    fn supports_live(&self) -> bool {
        true
    }
}
