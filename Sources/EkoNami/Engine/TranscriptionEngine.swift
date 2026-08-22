import AVFoundation
import Foundation

/// One buffer of captured audio, in transit from the audio thread to the speech engine.
///
/// `AVAudioPCMBuffer` isn't `Sendable`, and `AVAudioEngine` recycles the buffer it hands
/// to a tap the moment the callback returns. The unchecked conformance is only sound
/// because `AudioCapture` allocates a **fresh** buffer for every chunk and never touches
/// it again after handing it over — don't construct one of these around a borrowed buffer.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// A snapshot of the running transcript.
///
/// `text` is always the **full transcript so far**, not a delta — engines revise
/// earlier words as more audio arrives, so consumers should replace rather than append.
struct TranscriptionChunk: Sendable {
    let text: String
    /// `true` once the engine has committed everything it will emit for this session.
    let isFinal: Bool
}

/// The seam that keeps Eko Nami engine-agnostic. Implementing this protocol is the whole
/// cost of adding another open-source model.
protocol TranscriptionEngine: Actor {
    /// Audio format the engine wants buffers delivered in. `AudioCapture` converts to it.
    func preferredInputFormat() async -> AVAudioFormat?

    /// Prepare models and open a session. Emits snapshots until `finish()` is called.
    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error>

    /// Feed one buffer of captured microphone audio, already in `preferredInputFormat()`.
    func feed(_ chunk: AudioChunk) async

    /// Close the session and flush any pending final results.
    func finish() async
}

enum TranscriptionError: LocalizedError {
    case localeUnsupported(Locale)
    case modelInstallFailed(String)
    case noAudioFormat
    case notRunning

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let locale):
            return "Ditado não disponível para \(locale.identifier) neste Mac."
        case .modelInstallFailed(let detail):
            return "Falha ao instalar o modelo de fala: \(detail)"
        case .noAudioFormat:
            return "Nenhum formato de áudio compatível com a engine."
        case .notRunning:
            return "A engine de transcrição não está rodando."
        }
    }
}
