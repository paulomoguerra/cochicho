import Foundation
import Observation

/// Tracks which transcription model family currently occupies RAM and exposes
/// CARREGAR / DESCARREGAR for the Engine card.
@MainActor
@Observable
final class ModelResidence {
    static let shared = ModelResidence()

    enum Phase: Equatable {
        case idle
        case loading
        case unloading
    }

    var phase: Phase = .idle
    /// 0…1 while a load reports download/compile progress; nil otherwise.
    var downloadProgress: Double?
    var whisperLoaded: String?
    var parakeetLoaded: ParakeetVersion?
    var appleLoadedLocaleID: String?
    var lastError: String?

    /// Set once from `AppDelegate` so load/unload can refuse during dictation.
    weak var dictation: DictationController?

    var isBusy: Bool { phase != .idle }

    func refresh() async {
        async let whisper = WhisperModels.shared.loadedModel
        async let parakeet = ParakeetModels.shared.loadedVersion
        async let apple = AppleSpeechWarmup.shared.loadedLocaleID
        whisperLoaded = await whisper
        parakeetLoaded = await parakeet
        appleLoadedLocaleID = await apple
    }

    /// Preload whatever `AppSettings` currently selects for `settings.engine`.
    func loadSelected() async {
        guard dictation?.state.isActive != true else {
            lastError = "Ditado ativo"
            return
        }
        phase = .loading
        lastError = nil
        defer {
            phase = .idle
            downloadProgress = nil
        }

        let settings = AppSettings.shared
        await unloadOthers(keeping: settings.engine)

        do {
            switch settings.engine {
            case .whisper:
                guard WhisperModels.isDownloaded(settings.whisperModel) else {
                    lastError = "Modelo não baixado"
                    await refresh()
                    return
                }
                _ = try await WhisperModels.shared.pipe(for: settings.whisperModel)
            case .parakeet:
                _ = try await ParakeetModels.shared.manager(version: settings.parakeetVersion) { fraction in
                    Task { @MainActor in ModelResidence.shared.downloadProgress = fraction }
                }
            case .apple:
                try await AppleSpeechWarmup.shared.load(locale: settings.language.locale)
            }
        } catch is CancellationError {
            // Unload / switch cancelled an in-flight load — not a user-facing failure.
        } catch {
            lastError = error.localizedDescription
            Log.speech.error("ModelResidence load failed: \(error.localizedDescription)")
        }
        await refresh()
    }

    func unloadSelected() async {
        guard dictation?.state.isActive != true else {
            lastError = "Ditado ativo"
            return
        }
        phase = .unloading
        lastError = nil
        defer { phase = .idle }

        switch AppSettings.shared.engine {
        case .whisper:
            await WhisperModels.shared.unload()
        case .parakeet:
            await ParakeetModels.shared.unload()
        case .apple:
            await AppleSpeechWarmup.shared.unload()
        }
        await refresh()
    }

    /// Unload every family — used when switching engines.
    func unloadAll() async {
        phase = .unloading
        lastError = nil
        defer { phase = .idle }
        await WhisperModels.shared.unload()
        await ParakeetModels.shared.unload()
        await AppleSpeechWarmup.shared.unload()
        await refresh()
    }

    func unloadWhisperIfNeeded(keeping model: String) async {
        guard let whisperLoaded, whisperLoaded != model else { return }
        await WhisperModels.shared.unload()
        await refresh()
    }

    func unloadParakeetIfNeeded(keeping version: ParakeetVersion) async {
        guard let parakeetLoaded, parakeetLoaded != version else { return }
        await ParakeetModels.shared.unload()
        await refresh()
    }

    func unloadAppleIfNeeded(keeping language: Language) async {
        guard let appleLoadedLocaleID else { return }
        let kept = language.locale.identifier(.bcp47)
        let current = Locale(identifier: appleLoadedLocaleID).identifier(.bcp47)
        guard current != kept else { return }
        await AppleSpeechWarmup.shared.unload()
        await refresh()
    }

    /// Whether the currently selected engine's model is resident in RAM.
    func isSelectedInRAM(settings: AppSettings) -> Bool {
        switch settings.engine {
        case .whisper:
            return whisperLoaded == settings.whisperModel
        case .parakeet:
            return parakeetLoaded == settings.parakeetVersion
        case .apple:
            guard let appleLoadedLocaleID else { return false }
            return Locale(identifier: appleLoadedLocaleID).identifier(.bcp47)
                == settings.language.locale.identifier(.bcp47)
        }
    }

    private func unloadOthers(keeping engine: Engine) async {
        if engine != .whisper { await WhisperModels.shared.unload() }
        if engine != .parakeet { await ParakeetModels.shared.unload() }
        if engine != .apple { await AppleSpeechWarmup.shared.unload() }
    }
}
