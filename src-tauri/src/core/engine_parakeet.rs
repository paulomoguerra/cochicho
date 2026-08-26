//! Port de `ParakeetEngine.swift` — contrato alinhado ao Whisper (batch).
//!
//! **Batch, como o legacy.** O app Swift acumulava áudio e transcrevia uma vez no
//! stop — sem texto ao vivo no HUD. Aqui: `feed()` acumula f32 16 kHz mono;
//! `finish()` decodifica uma vez via sherpa-onnx (`nemo_transducer`).

use std::sync::{Arc, Mutex};

use sherpa_rs::transducer::{TransducerConfig, TransducerRecognizer};

use crate::core::engine::{
    ChunkTx, EngineAvailability, EngineError, TranscriptChunk, TranscriptionEngine,
};
use crate::core::models::{self, ParakeetOnnxPaths};

/// Hard backstop igual ao Swift: 10 min @ 16 kHz ≈ 38 MB.
const MAX_SAMPLES: usize = 16_000 * 600;
/// Encoder precisa de janela mínima — toque acidental de tecla não é fala.
const MIN_SAMPLES: usize = 1_600;

/// Um recognizer por processo, trocado se o modelo mudar.
static RECOGNIZER: Mutex<Option<(String, TransducerRecognizer)>> = Mutex::new(None);

pub struct ParakeetEngine {
    model_name: String,
    buffer: Arc<Mutex<Vec<f32>>>,
    tx: Option<ChunkTx>,
}

impl ParakeetEngine {
    pub fn new(model_name: &str) -> Self {
        Self {
            model_name: model_name.to_string(),
            buffer: Arc::new(Mutex::new(Vec::new())),
            tx: None,
        }
    }

    fn model_info(&self) -> Result<&'static models::ModelInfo, EngineError> {
        models::resolve_parakeet_model(&self.model_name).ok_or(EngineError::Unavailable)
    }

    fn onnx_paths(&self) -> Result<ParakeetOnnxPaths, EngineError> {
        let info = self.model_info()?;
        if !models::is_downloaded(info) {
            return Err(EngineError::ModelNotDownloaded);
        }
        models::parakeet_onnx_paths(&models::model_path(info))
            .ok_or_else(|| EngineError::Failed("modelo Parakeet incompleto em disco".into()))
    }
}

fn ensure_recognizer(model_name: &str, paths: &ParakeetOnnxPaths) -> Result<(), EngineError> {
    let mut slot = RECOGNIZER.lock().unwrap();
    if slot.as_ref().is_some_and(|(name, _)| name == model_name) {
        return Ok(());
    }
    let config = TransducerConfig {
        encoder: paths.encoder.to_string_lossy().into_owned(),
        decoder: paths.decoder.to_string_lossy().into_owned(),
        joiner: paths.joiner.to_string_lossy().into_owned(),
        tokens: paths.tokens.to_string_lossy().into_owned(),
        num_threads: 2,
        sample_rate: 16_000,
        feature_dim: 80,
        decoding_method: "greedy_search".into(),
        model_type: "nemo_transducer".into(),
        debug: false,
        ..Default::default()
    };
    let recognizer = TransducerRecognizer::new(config)
        .map_err(|e| EngineError::Failed(format!("carregar Parakeet: {e}")))?;
    *slot = Some((model_name.to_string(), recognizer));
    Ok(())
}

pub fn load_model(model_name: &str) -> Result<(), EngineError> {
    let info = models::resolve_parakeet_model(model_name).ok_or(EngineError::Unavailable)?;
    if !models::is_downloaded(info) {
        return Err(EngineError::ModelNotDownloaded);
    }
    let paths = models::parakeet_onnx_paths(&models::model_path(info))
        .ok_or_else(|| EngineError::Failed("modelo Parakeet incompleto em disco".into()))?;
    ensure_recognizer(model_name, &paths)
}

pub fn unload_model() {
    if let Ok(mut slot) = RECOGNIZER.lock() {
        *slot = None;
    }
}

pub fn loaded_model() -> Option<String> {
    RECOGNIZER
        .lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(|(name, _)| name.clone()))
}

fn transcribe(
    model_name: &str,
    paths: &ParakeetOnnxPaths,
    samples: &[f32],
) -> Result<String, EngineError> {
    ensure_recognizer(model_name, paths)?;
    let mut slot = RECOGNIZER.lock().unwrap();
    let recognizer = slot
        .as_mut()
        .map(|(_, rec)| rec)
        .ok_or(EngineError::Unavailable)?;
    Ok(recognizer.transcribe(16_000, samples).trim().to_string())
}

#[async_trait::async_trait]
impl TranscriptionEngine for ParakeetEngine {
    async fn start(&mut self, _prompt: &str, tx: ChunkTx) -> Result<(), EngineError> {
        let paths = self.onnx_paths()?;
        let model_name = self.model_name.clone();
        tokio::task::spawn_blocking(move || ensure_recognizer(&model_name, &paths))
            .await
            .map_err(|e| EngineError::Failed(e.to_string()))??;

        self.buffer.lock().unwrap().clear();
        self.tx = Some(tx);
        Ok(())
    }

    fn feed(&mut self, samples: &[f32]) {
        let mut buf = self.buffer.lock().unwrap();
        if buf.len() >= MAX_SAMPLES {
            return;
        }
        let room = MAX_SAMPLES - buf.len();
        let take = samples.len().min(room);
        buf.extend_from_slice(&samples[..take]);
    }

    async fn finish(&mut self) -> Result<(), EngineError> {
        let samples: Vec<f32> = std::mem::take(&mut *self.buffer.lock().unwrap());
        if samples.len() < MIN_SAMPLES {
            log::info!(
                "Parakeet: skipped — only {} samples captured",
                samples.len()
            );
            return Ok(());
        }

        let paths = self.onnx_paths()?;
        let model_name = self.model_name.clone();
        let text = tokio::task::spawn_blocking(move || transcribe(&model_name, &paths, &samples))
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
}

/// Nomes relativos esperados dentro do diretório extraído do tar.bz2.
#[allow(dead_code)]
pub fn expected_relative_files() -> [&'static str; 4] {
    [
        "encoder.int8.onnx",
        "decoder.int8.onnx",
        "joiner.int8.onnx",
        "tokens.txt",
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expected_files_are_non_empty() {
        for f in expected_relative_files() {
            assert!(!f.is_empty());
        }
    }

    #[test]
    fn new_engine_availability_matches_disk_state() {
        let engine = ParakeetEngine::new("parakeet-tdt-0.6b-v3");
        let info = models::resolve_parakeet_model("parakeet-tdt-0.6b-v3").unwrap();
        let expected = if models::is_downloaded(info) {
            EngineAvailability::Available
        } else {
            EngineAvailability::NeedsDownload
        };
        assert_eq!(engine.availability(), expected);
    }

    #[test]
    fn sample_limits_match_legacy() {
        assert_eq!(MIN_SAMPLES, 1_600);
        assert_eq!(MAX_SAMPLES, 16_000 * 600);
    }
}
