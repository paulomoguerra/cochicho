import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Streaming on-device transcription via macOS 26's `SpeechAnalyzer` / `SpeechTranscriber`.
///
/// No model ships with the app — the OS downloads and manages the assets, so the first
/// run for a given locale may block briefly while `AssetInstallationRequest` completes.
actor AppleSpeechEngine: TranscriptionEngine {
    private let locale: Locale

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Text the engine has committed. Volatile results are appended on top for display
    /// but discarded as soon as a final result covering the same range arrives.
    private var finalizedText = ""

    /// Monotonic timeline for `AnalyzerInput` — without it, SpeechAnalyzer often withholds
    /// volatile results until `finalize`, which is why the HUD looked "dead" while talking.
    private var nextBufferTime = CMTime.zero

    init(locale: Locale) {
        self.locale = locale
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        let module = transcriber ?? Self.makeTranscriber(locale: locale)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.localeUnsupported(locale)
        }

        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            ?? Locale(identifier: "en-US")

        let transcriber = Self.makeTranscriber(locale: resolvedLocale)
        self.transcriber = transcriber

        try await Self.ensureModelInstalled(for: transcriber)

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // Bias the recognizer toward the dictionary's words before it hears anything. A
        // nudge, not a guarantee — `DictionaryCorrector` is the pass that enforces spelling.
        // Capped: a long context list makes these models drift on quiet or ambiguous audio.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if let context = await Self.context() {
            try? await analyzer.setContext(context)
        }

        // Preheat so the first volatile result isn't stuck behind a cold model load.
        try await analyzer.prepareToAnalyze(in: format)

        finalizedText = ""
        nextBufferTime = .zero

        let (chunks, chunkContinuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()

        // Drain the transcriber's results into our simpler chunk stream.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let snapshot = await self.absorb(result)
                    if !snapshot.isEmpty {
                        chunkContinuation.yield(TranscriptionChunk(text: snapshot, isFinal: result.isFinal))
                    }
                }
                let final = await self?.finalizedText ?? ""
                if !final.isEmpty {
                    chunkContinuation.yield(TranscriptionChunk(text: final, isFinal: true))
                }
                chunkContinuation.finish()
            } catch {
                Log.speech.error("results stream failed: \(error.localizedDescription)")
                chunkContinuation.finish(throwing: error)
            }
        }

        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            // Without this, `resultsTask` sits on `transcriber.results` forever and leaks
            // both the task and the transcriber it captured.
            resultsTask?.cancel()
            resultsTask = nil
            chunkContinuation.finish(throwing: error)
            inputContinuation.finish()
            self.inputContinuation = nil
            self.analyzer = nil
            self.transcriber = nil
            throw error
        }
        Log.speech.info("SpeechAnalyzer started for \(resolvedLocale.identifier) (volatile+fast)")

        return chunks
    }

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }

        let start = nextBufferTime
        let duration = CMTime(
            value: CMTimeValue(buffer.frameLength),
            timescale: CMTimeScale(max(1, Int32(buffer.format.sampleRate.rounded())))
        )
        nextBufferTime = CMTimeAdd(start, duration)

        inputContinuation?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
    }

    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.speech.error("finalize failed: \(error.localizedDescription)")
            await analyzer?.cancelAndFinishNow()
        }

        // Let the results task drain the final yields before we tear the refs down.
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil
    }

    // MARK: - Result accumulation

    /// Folds one result into the running transcript and returns the full text to display.
    private func absorb(_ result: SpeechTranscriber.Result) -> String {
        let text = String(result.text.characters)
        guard result.isFinal else {
            return (finalizedText + text).trimmingCharacters(in: .whitespaces)
        }
        finalizedText += text
        return finalizedText.trimmingCharacters(in: .whitespaces)
    }

    /// Warms the OS speech stack for a locale so the first real dictation skips the cold
    /// model load. Only touches models that are already installed — never downloads.
    static func preheat(locale: Locale) async {
        guard SpeechTranscriber.isAvailable else { return }
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            ?? Locale(identifier: "en-US")
        let transcriber = makeTranscriber(locale: resolved)

        let installed = await SpeechTranscriber.installedLocales
        let ready = transcriber.selectedLocales.allSatisfy { locale in
            installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        }
        guard ready,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try? await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
        Log.speech.info("preheated speech model for \(resolved.identifier)")
    }

    // MARK: - Setup helpers

    /// The dictionary's words, handed to the analyzer as contextual strings.
    ///
    /// Hops to the main actor rather than asserting it — `MainActor.assumeIsolated` from
    /// the engine's own executor doesn't check the claim, it takes the process down.
    private static func context() async -> AnalysisContext? {
        let phrases = await MainActor.run { DictionaryStore.shared.biasPhrases }
        guard !phrases.isEmpty else { return nil }

        let context = AnalysisContext()
        context.contextualStrings[.general] = phrases
        return context
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // `volatileResults` = live guesses while speaking.
            // `fastResults` = lower latency (the missing piece that made the HUD feel dead).
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    private static func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let selected = transcriber.selectedLocales
        let alreadyThere = selected.allSatisfy { locale in
            installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        }
        guard !alreadyThere else { return }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.speech.info("downloading speech model…")
                try await request.downloadAndInstall()
                Log.speech.info("speech model installed")
            }
        } catch {
            throw TranscriptionError.modelInstallFailed(error.localizedDescription)
        }
    }
}
