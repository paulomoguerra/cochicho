//! Port de `WhisperEngine.swift` usando whisper.cpp (whisper-rs) no lugar do WhisperKit.
//!
//! **Batch, como o legacy.** O WhisperKit do app Swift também emitia só o chunk
//! final no stop — sem parciais no HUD. Aqui: `feed()` acumula; `finish()`
//! transcreve uma vez. Sem live preview periódico (re-decode a cada ~2s seria
//! custo CPU alto no tiny/base e o legacy não fazia).

use std::sync::{Arc, Mutex};

use crate::core::engine::{ChunkTx, EngineAvailability, EngineError, TranscriptChunk, TranscriptionEngine};
use crate::core::models;
use crate::core::settings::Language;

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
        let info = self.model_info()?;
        let path = models::model_path(info);
        if !models::is_downloaded(info) {
            return Err(EngineError::ModelNotDownloaded);
        }
        let path_str = path.to_string_lossy().to_string();
        let ctx = whisper_rs::WhisperContext::new_with_params(
            &path_str,
            whisper_rs::WhisperContextParameters::default(),
        )
        .map_err(|e| EngineError::Failed(format!("load whisper model: {e}")))?;
        self.context = Some(Arc::new(ctx));
        Ok(())
    }
}

#[async_trait::async_trait]
impl TranscriptionEngine for WhisperEngine {
    async fn start(&mut self, prompt: &str, tx: ChunkTx) -> Result<(), EngineError> {
        let mut engine = Self {
            model_name: self.model_name.clone(),
            language: self.language,
            context: None,
            buffer: self.buffer.clone(),
            tx: None,
            prompt: String::new(),
        };
        // Carregar o modelo é bloqueante e pesado — fora da thread async.
        tokio::task::spawn_blocking(move || engine.ensure_context())
            .await
            .map_err(|e| EngineError::Failed(e.to_string()))??;

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
            let _ = tx.send(TranscriptChunk { text, is_final: true });
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
