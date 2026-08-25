//! Port de `WhisperEngine.swift` usando whisper.cpp (whisper-rs) no lugar do WhisperKit.
//!
//! **Batch, como o legacy.** O WhisperKit do app Swift também emitia só o chunk
//! final no stop — sem parciais no HUD. Aqui: `feed()` acumula; `finish()`
//! transcreve uma vez. Sem live preview periódico (re-decode a cada ~2s seria
//! custo CPU alto no tiny/base e o legacy não fazia).

use std::sync::{Arc, Mutex};

use crate::core::engine::{
    ChunkTx, EngineAvailability, EngineError, TranscriptChunk, TranscriptionEngine,
};
use crate::core::models;
use crate::core::settings::Language;

/// Contexto compartilhado para o modelo ficar realmente residente entre gravações.
static WHISPER_CONTEXT: Mutex<Option<(String, Arc<whisper_rs::WhisperContext>)>> = Mutex::new(None);

fn context_for_model(model_name: &str) -> Result<Arc<whisper_rs::WhisperContext>, EngineError> {
    let mut slot = WHISPER_CONTEXT
        .lock()
        .map_err(|_| EngineError::Failed("estado do Whisper corrompido".into()))?;
    if let Some((loaded_name, context)) = slot.as_ref() {
        if loaded_name == model_name {
            return Ok(context.clone());
        }
    }

    let info = models::resolve_whisper_model(model_name).ok_or(EngineError::Unavailable)?;
    let path = models::model_path(info);
    if !models::is_downloaded(info) {
        return Err(EngineError::ModelNotDownloaded);
    }
    let context = Arc::new(
        whisper_rs::WhisperContext::new_with_params(
            path.to_string_lossy().as_ref(),
            whisper_rs::WhisperContextParameters::default(),
        )
        .map_err(|e| EngineError::Failed(format!("load whisper model: {e}")))?,
    );
    *slot = Some((model_name.to_string(), context.clone()));
    Ok(context)
}

pub fn load_model(model_name: &str) -> Result<(), EngineError> {
    context_for_model(model_name).map(|_| ())
}

pub fn unload_model() {
    if let Ok(mut slot) = WHISPER_CONTEXT.lock() {
        *slot = None;
    }
}

pub fn loaded_model() -> Option<String> {
    WHISPER_CONTEXT
        .lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(|(name, _)| name.clone()))
}

pub struct WhisperEngine {
    model_name: String,
    language: Language,
    context: Option<Arc<whisper_rs::WhisperContext>>,
    buffer: Arc<Mutex<Vec<f32>>>,
    tx: Option<ChunkTx>,
    prompt: String,
}

impl WhisperEngine {
    pub fn new(model_name: &str, language: Language) -> Self {
        Self {
            model_name: model_name.to_string(),
            language,
            context: None,
            buffer: Arc::new(Mutex::new(Vec::new())),
            tx: None,
            prompt: String::new(),
        }
    }

    fn model_info(&self) -> Result<&'static models::ModelInfo, EngineError> {
        models::resolve_whisper_model(&self.model_name).ok_or(EngineError::Unavailable)
    }

    fn ensure_context(&mut self) -> Result<(), EngineError> {
        if self.context.is_some() {
            return Ok(());
        }
        self.context = Some(context_for_model(&self.model_name)?);
        Ok(())
    }
}

#[async_trait::async_trait]
impl TranscriptionEngine for WhisperEngine {
    async fn start(&mut self, prompt: &str, tx: ChunkTx) -> Result<(), EngineError> {
        let model_name = self.model_name.clone();
        // Carregar o modelo é bloqueante e pesado — fora da thread async.
        let context = tokio::task::spawn_blocking(move || context_for_model(&model_name))
            .await
            .map_err(|e| EngineError::Failed(e.to_string()))??;

        self.context = Some(context);
        self.buffer.lock().unwrap().clear();
        self.tx = Some(tx);
        self.prompt = prompt.to_string();
        Ok(())
    }

    fn feed(&mut self, samples: &[f32]) {
        self.buffer.lock().unwrap().extend_from_slice(samples);
    }

    async fn finish(&mut self) -> Result<(), EngineError> {
        self.ensure_context()?;
        let ctx = self.context.clone().ok_or(EngineError::Unavailable)?;
        let samples: Vec<f32> = std::mem::take(&mut *self.buffer.lock().unwrap());
        let language = self.language.whisper_code().to_string();
        let prompt = self.prompt.clone();

        let text = tokio::task::spawn_blocking(move || -> Result<String, EngineError> {
            let mut state = ctx
                .create_state()
                .map_err(|e| EngineError::Failed(format!("whisper state: {e}")))?;

            let mut params =
                whisper_rs::FullParams::new(whisper_rs::SamplingStrategy::Greedy { best_of: 1 });
            params.set_language(Some(&language));
            if !prompt.is_empty() {
                params.set_initial_prompt(&prompt);
            }
            params.set_print_special(false);
            params.set_print_progress(false);
            params.set_print_realtime(false);
            params.set_print_timestamps(false);
            params.set_suppress_blank(true);
            params.set_single_segment(false);
            params.set_no_timestamps(true);

            state
                .full(params, &samples)
                .map_err(|e| EngineError::Failed(format!("whisper inference: {e}")))?;

            let mut text = String::new();
            for segment in state.as_iter() {
                if let Ok(piece) = segment.to_str_lossy() {
                    text.push_str(&piece);
                }
            }
            Ok(text.trim().to_string())
        })
        .await
        .map_err(|e| EngineError::Failed(e.to_string()))??;

        if let Some(tx) = &self.tx {
            let _ = tx.send(TranscriptChunk {
                text,
                is_final: true,
            });
        }
        Ok(())
    }

    async fn cancel(&mut self) {
        self.buffer.lock().unwrap().clear();
        self.tx = None;
    }

    fn availability(&self) -> EngineAvailability {
        match self.model_info() {
            Ok(info) if models::is_downloaded(info) => EngineAvailability::Available,
            Ok(_) => EngineAvailability::NeedsDownload,
            Err(_) => EngineAvailability::Unavailable,
        }
    }

    fn supports_live(&self) -> bool {
        false
    }
}
