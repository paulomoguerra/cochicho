import AVFoundation
import FluidAudio
import Foundation
import WhisperKit

/// OpenAI Whisper family via WhisperKit (Argmax), compiled to CoreML.
///
/// **Batch, not streaming** — same shape as `ParakeetEngine`: audio accumulates while
/// recording and transcribes in one pass on stop. Which checkpoint runs is the user's
/// pick from the catalog (`AppSettings.whisperModel`).
actor WhisperEngine: TranscriptionEngine {
    /// Same backstop as Parakeet: 10 minutes of 16 kHz audio, then buffers are dropped.
    private static let maxSamples = 16_000 * 600

    private let model: String
    private let language: String
    private var samples: [Float] = []
    private var reportedOverflow = false
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    /// FluidAudio's converter — 16 kHz mono float32, exactly what Whisper wants too.
    private let converter = AudioConverter()

    init(model: String, language: String) {
        self.model = model
        self.language = language
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)
        reportedOverflow = false

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation

        // Load (or download) before the user speaks, not after they release the key.
        _ = try await WhisperModels.shared.pipe(for: model)

        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }

        guard samples.count < Self.maxSamples else {
            if !reportedOverflow {
                reportedOverflow = true
                Log.speech.error("Whisper: dictation exceeded 10 min — dropping further audio")
            }
            return
        }

        do {
            samples.append(contentsOf: try converter.resampleBuffer(buffer))
        } catch {
            Log.speech.error("Whisper: audio conversion failed — \(error.localizedDescription)")
        }
    }

    func finish() async {
        defer {
            continuation?.finish()
            continuation = nil
            samples.removeAll(keepingCapacity: true)
        }

        guard samples.count >= 1_600 else {
            Log.speech.info("Whisper: skipped — only \(self.samples.count) samples captured")
            return
        }

        do {
            let pipe = try await WhisperModels.shared.pipe(for: model)

            // English-only checkpoints (".en") reject a language hint; multilingual ones
            // need it or short pt-BR clips get misdetected.
            let hint: String? = WhisperModels.isEnglishOnly(model) ? nil : language
            let options = DecodingOptions(
                task: .transcribe,
                language: hint,
                skipSpecialTokens: true,
                // VAD chunking parallelizes utterances longer than Whisper's 30 s window.
                chunkingStrategy: .vad
            )

            let started = Date()
            let results: [TranscriptionResult] = try await pipe.transcribe(
                audioArray: samples, decodeOptions: options
            )
            let elapsed = Date().timeIntervalSince(started)
            let audioSeconds = Double(samples.count) / 16_000

            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            Log.speech.info("""
                Whisper(\(self.model, privacy: .public)): \
                \(audioSeconds, format: .fixed(precision: 1))s audio in \
                \(elapsed, format: .fixed(precision: 2))s
                """)

            continuation?.yield(TranscriptionChunk(text: text, isFinal: true))
        } catch {
            Log.speech.error("Whisper failed: \(error.localizedDescription)")
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - Model catalog & cache

/// Process-wide WhisperKit model manager: catalog listing, download, load, delete.
///
/// Models live under Application Support/EkoNami/WhisperKit/, mirroring the Hugging
/// Face repo layout WhisperKit expects. Only one pipeline stays loaded at a time —
/// large-v3 alone is multiple GB of RAM.
actor WhisperModels {
    static let shared = WhisperModels()

    static let repo = "argmaxinc/whisperkit-coreml"

    /// Catalog fallback when the Hugging Face listing can't be reached. Names must match
    /// the repo's folder names exactly.
    static let curated: [String] = [
        "openai_whisper-tiny",
        "openai_whisper-tiny.en",
        "openai_whisper-base",
        "openai_whisper-base.en",
        "openai_whisper-small",
        "openai_whisper-small.en",
        "openai_whisper-medium",
        "openai_whisper-medium.en",
        "openai_whisper-large-v3",
        "openai_whisper-large-v3_947MB",
        "openai_whisper-large-v3-v20240930",
        "openai_whisper-large-v3-v20240930_626MB",
        "distil-whisper_distil-large-v3",
    ]

    /// Rough on-disk size per known variant, for the catalog UI.
    static func approximateSize(of model: String) -> String? {
        if let tagged = model.split(separator: "_").last, tagged.hasSuffix("MB"),
           let value = Int(tagged.dropLast(2)) {
            return value >= 1000 ? String(format: "%.1f GB", Double(value) / 1000) : "\(value) MB"
        }
        let sizes: [String: String] = [
            "tiny": "150 MB", "base": "290 MB", "small": "900 MB",
            "medium": "3 GB", "large-v3": "3 GB", "large-v3-v20240930": "1.6 GB",
            "distil-large-v3": "1.5 GB",
        ]
        let bare = model
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "distil-whisper_", with: "")
            .replacingOccurrences(of: ".en", with: "")
        return sizes[bare]
    }

    static func isEnglishOnly(_ model: String) -> Bool { model.hasSuffix(".en") }

    /// Short display name for the catalog: "openai_whisper-large-v3_947MB" → "LARGE-V3 947MB",
    /// "distil-whisper_distil-large-v3" → "DISTIL-LARGE-V3".
    static func displayName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "distil-whisper_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .uppercased()
    }

    nonisolated static var downloadBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("EkoNami/WhisperKit", isDirectory: true)
    }

    nonisolated static func modelFolder(_ model: String) -> URL {
        downloadBase.appendingPathComponent("models/\(repo)/\(model)", isDirectory: true)
    }

    /// On-disk check without loading — the catalog UI needs this synchronously.
    nonisolated static func isDownloaded(_ model: String) -> Bool {
        FileManager.default.fileExists(
            atPath: modelFolder(model).appendingPathComponent("MelSpectrogram.mlmodelc").path
        )
    }

    /// The device-compatible catalog straight from Hugging Face, curated list as the
    /// offline fallback. Downloaded models always appear even if delisted upstream.
    static func availableModels() async -> [String] {
        var names = (try? await WhisperKit.fetchAvailableModels(from: repo)) ?? []
        if names.isEmpty { names = curated }
        // The hub writes bookkeeping folders (".cache") next to the models — only merge
        // real model folders, verified by their contents.
        let onDisk = (try? FileManager.default.contentsOfDirectory(
            atPath: downloadBase.appendingPathComponent("models/\(repo)").path
        )) ?? []
        for model in onDisk where !model.hasPrefix(".") && !names.contains(model) && isDownloaded(model) {
            names.append(model)
        }
        return names.sorted { displayName($0) < displayName($1) }
    }

    func download(
        _ model: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(
            variant: model,
            downloadBase: Self.downloadBase,
            from: Self.repo,
            progressCallback: { progress($0.fractionCompleted) }
        )
    }

    func delete(_ model: String) {
        if loaded?.model == model {
            loaded = nil
            loadTask = nil
        }
        try? FileManager.default.removeItem(at: Self.modelFolder(model))
        Log.speech.info("Whisper: deleted \(model, privacy: .public)")
    }

    /// Actual bytes on disk for a downloaded model — what the catalog shows next to it.
    static func diskSize(of model: String) async -> Int64 {
        await directorySize(at: modelFolder(model))
    }

    private var loaded: (model: String, pipe: WhisperKit)?
    private var loadTask: (model: String, task: Task<WhisperKit, Error>)?

    var loadedModel: String? { loaded?.model }
    var isLoading: Bool { loadTask != nil }
    func isLoaded(_ model: String) -> Bool { loaded?.model == model }

    /// Drop pipeline from RAM; does not delete disk files.
    func unload() {
        loaded = nil
        loadTask?.task.cancel()
        loadTask = nil
        Log.speech.info("Whisper: unloaded from RAM")
    }

    /// Loads once per model; switching models drops the previous pipeline from RAM.
    func pipe(for model: String) async throws -> WhisperKit {
        if let loaded, loaded.model == model { return loaded.pipe }
        if let loadTask, loadTask.model == model { return try await loadTask.task.value }

        loaded = nil
        loadTask?.task.cancel()
        loadTask = nil
        let task = Task<WhisperKit, Error> {
            let stage = Self.isDownloaded(model) ? "loading from disk" : "downloading"
            Log.speech.info("Whisper \(model, privacy: .public): \(stage, privacy: .public)")
            let started = Date()
            let config = WhisperKitConfig(
                model: model,
                downloadBase: Self.downloadBase,
                modelRepo: Self.repo,
                prewarm: true,
                load: true,
                download: true
            )
            let pipe = try await WhisperKit(config)
            Log.speech.info("Whisper: ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            return pipe
        }
        loadTask = (model, task)

        do {
            let pipe = try await task.value
            loaded = (model, pipe)
            loadTask = nil
            return pipe
        } catch {
            loadTask = nil
            throw error
        }
    }
}
