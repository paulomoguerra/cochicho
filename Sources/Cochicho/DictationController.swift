import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current settings. Read per-utterance so an engine or
/// language change in the UI takes effect on the very next dictation, no restart.
@Sendable
func engineForCurrentSetting() -> any TranscriptionEngine {
    MainActor.assumeIsolated {
        switch AppSettings.shared.engine {
        case .apple: AppleSpeechEngine(locale: AppSettings.shared.language.locale)
        case .parakeet: ParakeetEngine()
        }
    }
}

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }
    }

    private(set) var state: State = .idle
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0
    /// Whether the hotkey tap is armed (false ⇒ missing Accessibility).
    private(set) var hotkeyArmed = false

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @Sendable () -> any TranscriptionEngine

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

    private var holdStarted: Date?
    private var releasedAt: Date?
    private var engineName = ""
    private var languageName = ""

    init(makeEngine: @escaping @Sendable () -> any TranscriptionEngine = engineForCurrentSetting) {
        self.makeEngine = makeEngine
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the hotkey tap couldn't be installed (missing Accessibility).
    @discardableResult
    func activate() -> Bool {
        hotkey.spec = AppSettings.shared.hotkey
        hotkey.mode = AppSettings.shared.hotkeyMode
        hotkey.onPress = { [weak self] in self?.beginDictation() }
        hotkey.onRelease = { [weak self] in self?.endDictation() }
        hotkey.onToggle = { [weak self] in
            guard let self else { return }
            if self.state.isActive {
                self.endDictation()
            } else {
                self.beginDictation()
            }
        }
        hotkeyArmed = hotkey.start()
        return hotkeyArmed
    }

    func deactivate() {
        hotkey.stop()
        hotkeyArmed = false
        cancelDictation()
    }

    /// Re-arms the tap after the user picks a different key or mode.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkey.stop()
        return activate()
    }

    /// Manual start/stop from the dashboard's record button.
    func toggleFromUI() {
        if state.isActive {
            endDictation()
        } else {
            beginDictation()
        }
    }

    // MARK: - Dictation

    private func beginDictation() {
        guard case .idle = state else { return }
        state = .starting
        transcript = ""
        holdStarted = Date()
        engineName = AppSettings.shared.engine.displayName
        languageName = AppSettings.shared.language.rawValue

        Task { @MainActor in
            do {
                guard await Permissions.requestMicrophone() else {
                    fail("Microfone bloqueado. Ative em Ajustes ▸ Privacidade ▸ Microfone.")
                    return
                }

                let engine = makeEngine()
                self.engine = engine

                let chunks = try await engine.start()

                guard let format = await engine.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }

                // Audio must reach the engine in capture order. A stream plus a single
                // draining task guarantees that; a Task per buffer would not.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
                self.audioContinuation = audioContinuation

                self.feedTask = Task.detached(priority: .userInitiated) {
                    for await chunk in audioStream {
                        await engine.feed(chunk)
                    }
                }

                try capture.start(
                    outputFormat: format,
                    onBuffer: { chunk in
                        audioContinuation.yield(chunk)
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.updateLevel(level) }
                    }
                )

                // Bail out if the user already let go while we were spinning up.
                guard case .starting = self.state else {
                    await self.teardown()
                    return
                }

                self.state = .listening
                if AppSettings.shared.soundEnabled { NSSound(named: "Tink")?.play() }

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks {
                            self.transcript = chunk.text
                        }
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func endDictation() {
        // `.finishing` counts as active, so without the extra guard a second press during
        // processing would run the whole tail again and paste the same utterance twice.
        // The window is wide: Parakeet transcribes inside `finish()`.
        guard state.isActive, state != .finishing else { return }
        state = .finishing
        capture.stop()
        level = 0
        releasedAt = Date()

        Task { @MainActor in
            // Drain every captured buffer into the engine before asking it to finalize,
            // or the tail of the utterance gets dropped.
            audioContinuation?.finish()
            audioContinuation = nil
            await feedTask?.value
            feedTask = nil

            await engine?.finish()
            await consumeTask?.value
            consumeTask = nil
            engine = nil

            let raw = transcript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .idle
                transcript = ""
                return
            }

            // The dictionary runs last and unconditionally — biasing only raises the odds
            // of the right word; this is the pass that guarantees it.
            let (output, corrections) = DictionaryStore.shared.corrector.apply(to: raw)

            // Show the final (corrected) line on the HUD for a beat so Grande is readable
            // before the panel dismisses with `.idle`.
            transcript = output
            recordRun(text: output, corrections: corrections)
            TextInjector.insert(output)
            if AppSettings.shared.soundEnabled { NSSound(named: "Pop")?.play() }

            let hold: Duration = AppSettings.shared.hudSize == .large
                ? .milliseconds(1600)
                : .milliseconds(700)
            try? await Task.sleep(for: hold)

            state = .idle
            transcript = ""
        }
    }

    private func cancelDictation() {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil

        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }

        state = .idle
        transcript = ""
        level = 0
    }

    private func teardown() async {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        await feedTask?.value
        feedTask = nil
        await engine?.finish()
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .idle
    }

    // MARK: - Helpers

    private func recordRun(text: String, corrections: [AppliedCorrection]) {
        guard let holdStarted, let releasedAt else { return }
        HistoryStore.shared.record(
            HistoryEntry(
                id: UUID(),
                date: releasedAt,
                text: text,
                engine: engineName,
                language: languageName,
                audioSeconds: releasedAt.timeIntervalSince(holdStarted),
                processSeconds: Date().timeIntervalSince(releasedAt),
                corrections: corrections.isEmpty ? nil : corrections
            )
        )
        self.holdStarted = nil
        self.releasedAt = nil
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    private func fail(_ message: String) {
        Log.app.error("\(message)")
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .error(message)
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle }
        }
    }
}
