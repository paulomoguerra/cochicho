//! Port de `ParakeetEngine.swift` — contrato alinhado ao Whisper (batch).
//!
//! **Batch, como o legacy.** O app Swift acumulava áudio e transcrevia uma vez no
//! stop — sem texto ao vivo no HUD. Aqui: `feed()` acumula f32 16 kHz mono;
//! `finish()` deveria decodificar uma vez. Sem live preview periódico.
//!
//! **sherpa-rs (fallback M2):** a integração real via `sherpa-rs` (bindings +
//! prebuilt sherpa-onnx) ficou bloqueada neste ambiente — `crates.io` timeout
//! persistente + ~9 GB livres (prebuilt + ONNXRuntime estouram o disco). O
//! download/extração do modelo e o onboarding Linux seguem funcionando; a
//! inferência retorna erro claro até o próximo passo: adicionar
//! `sherpa-rs = { version = "0.6", default-features = false, features = ["download-binaries"] }`
//! e completar `ensure_recognizer()` com `TransducerRecognizer`
//! (`model_type: "nemo_transducer"`).

use std::sync::{Arc, Mutex};

use crate::core::engine::{ChunkTx, EngineAvailability, EngineError, TranscriptChunk, TranscriptionEngine};
use crate::core::models;
use crate::core::settings::ParakeetVersion;

/// Hard backstop igual ao Swift: 10 min @ 16 kHz ≈ 38 MB.
const MAX_SAMPLES: usize = 16_000 * 600;
/// Encoder precisa de janela mínima — toque acidental de tecla não é fala.
const MIN_SAMPLES: usize = 1_600;

const SHERPA_BLOCKED: &str = "Parakeet: sherpa-rs indisponível neste build \
(crates.io timeout + disco limitado). Baixe o modelo normalmente; a inferência \
chega quando sherpa-rs linkar. Ver cabeçalho de engine_parakeet.rs.";

pub struct ParakeetEngine {
    version: ParakeetVersion,
    buffer: Arc<Mutex<Vec<f32>>>,
    tx: Option<ChunkTx>,
}

impl ParakeetEngine {
    pub fn new(version: ParakeetVersion) -> Self {
        Self {
            version,
            buffer: Arc::new(Mutex::new(Vec::new())),
            tx: None,
        }
    }

    fn model_info(&self) -> Result<&'static models::ModelInfo, EngineError> {
        models::resolve_parakeet_model(self.version.model_name()).ok_or(EngineError::Unavailable)
    }
}

#[async_trait::async_trait]
impl TranscriptionEngine for ParakeetEngine {
    async fn start(&mut self, _prompt: &str, _tx: ChunkTx) -> Result<(), EngineError> {
        let info = self.model_info()?;
        if !models::is_downloaded(info) {
            return Err(EngineError::ModelNotDownloaded);
        }
        // Modelo em disco ok — falta o runtime sherpa-onnx.
        Err(EngineError::Failed(SHERPA_BLOCKED.into()))
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
        if let Some(tx) = &self.tx {
            let _ = tx.send(TranscriptChunk {
                text: String::new(),
                is_final: true,
            });
        }
        Err(EngineError::Failed(SHERPA_BLOCKED.into()))
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
    fn new_engine_needs_download_without_files() {
        let engine = ParakeetEngine::new(ParakeetVersion::V3);
        assert_eq!(engine.availability(), EngineAvailability::NeedsDownload);
    }

    #[test]
    fn sample_limits_match_legacy() {
        assert_eq!(MIN_SAMPLES, 1_600);
        assert_eq!(MAX_SAMPLES, 16_000 * 600);
    }
}
