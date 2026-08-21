import AVFoundation
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

        // Bias the recognizer toward the dictionary's words before it hears anything. A
        // nudge, not a guarantee — `DictionaryCorrector` is the pass that enforces spelling.
        // Capped: a long context list makes these models drift on quiet or ambiguous audio.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if let context = await Self.context() {
            try? await analyzer.setContext(context)
        }

        finalizedText = ""

        let (chunks, chunkContinuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()

        // Drain the transcriber's results into our simpler chunk stream.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let snapshot = await self.absorb(result)
                    chunkContinuation.yield(TranscriptionChunk(text: snapshot, isFinal: false))
                }
                let final = await self?.finalizedText ?? ""
                chunkContinuation.yield(TranscriptionChunk(text: final, isFinal: true))
                chunkContinuation.finish()
            } catch {
                Log.speech.error("results stream failed: \(error.localizedDescription)")
                chunkContinuation.finish(throwing: error)
            }
        }

        try await analyzer.start(inputSequence: inputStream)
        Log.speech.info("SpeechAnalyzer started for \(resolvedLocale.identifier)")

        return chunks
    }

    func feed(_ chunk: AudioChunk) async {
        inputContinuation?.yield(AnalyzerInput(buffer: chunk.buffer))
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

        analyzer = nil
        transcriber = nil
        resultsTask = nil
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
            // `.volatileResults` is what makes live text appear while you're still talking.
            reportingOptions: [.volatileResults],
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
