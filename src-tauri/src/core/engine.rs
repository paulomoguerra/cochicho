//! Port de `TranscriptionEngine.swift` — o contrato que mantém o ditado agnóstico de
//! engine. O controller só conhece este trait; engines vivem atrás dele.

use async_trait::async_trait;
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EngineAvailability {
    Available,
    NeedsDownload,
    Unavailable,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct TranscriptChunk {
    pub text: String,
    pub is_final: bool,
}

pub type ChunkTx = tokio::sync::mpsc::UnboundedSender<TranscriptChunk>;

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("model not downloaded")]
    ModelNotDownloaded,
    #[error("engine unavailable on this platform")]
    Unavailable,
    #[error("engine failed: {0}")]
    Failed(String),
}

/// Um chunk por engine: Apple transmite ao vivo; Parakeet/Whisper acumulam e mandam
/// uma vez no finish().
#[async_trait]
pub trait TranscriptionEngine: Send {
    /// Prepara para uma sessão; prompt = frases de viés do dicionário.
    async fn start(&mut self, prompt: &str, tx: ChunkTx) -> Result<(), EngineError>;

    /// Alimenta áudio (f32 mono a 16 kHz). Chamado pela task de consumo do controller.
    fn feed(&mut self, samples: &[f32]);

    /// Fecha a sessão. A engine emite seus chunks finais no tx antes de retornar.
    async fn finish(&mut self) -> Result<(), EngineError>;

    /// Descarta tudo sem emitir.
    async fn cancel(&mut self);

    fn availability(&self) -> EngineAvailability;
    fn supports_live(&self) -> bool;
}
