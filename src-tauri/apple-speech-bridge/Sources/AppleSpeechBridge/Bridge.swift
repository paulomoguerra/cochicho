import AVFoundation
import CoreMedia
import Foundation
import Speech

/// C ABI entre o core Rust e o Speech framework (Swift-only).
///
/// ABI v2 — sessão streaming:
///   ekonami_asb_speech_available / ekonami_asb_bridge_version
///   ekonami_asb_mic_status / ekonami_asb_mic_request
///   ekonami_asb_session_start / feed / finish / cancel
///
/// Callback `ekonami_asb_chunk_cb(user_data, text, kind)`:
///   kind 0 = partial (volatile), 1 = final chunk, 2 = error, 3 = ended
///   `text` é UTF-8 válido só durante a chamada — o caller copia.
///
/// Threading: o callback dispara na fila do Speech framework. O lado Rust
/// encaminha via `tokio::sync::mpsc::UnboundedSender` (Send) direto no callback.
///
/// Assunções a validar no device (não dá para exercitar aqui):
/// - SpeechAnalyzer/SpeechTranscriber APIs de macOS 26 batem com o legacy
/// - bestAvailableAudioFormat + AVAudioConverter a partir de 16 kHz mono f32
/// - setContext(contextualStrings) aceita a lista de bias do dicionário

public typealias EkonamiAsbChunkCb = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    Int32
) -> Void

private enum ChunkKind {
    static let partial: Int32 = 0
    static let finalChunk: Int32 = 1
    static let error: Int32 = 2
    static let ended: Int32 = 3
}

@_cdecl("ekonami_asb_speech_available")
public func ekonami_asb_speech_available() -> Int32 {
    SpeechTranscriber.isAvailable ? 1 : 0
}

@_cdecl("ekonami_asb_bridge_version")
public func ekonami_asb_bridge_version() -> Int32 {
    2
}

/// AVAuthorizationStatus raw: 0 notDetermined, 1 restricted, 2 denied, 3 authorized.
@_cdecl("ekonami_asb_mic_status")
public func ekonami_asb_mic_status() -> Int32 {
    Int32(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)
}

/// Bloqueia até o usuário responder (ou já autorizado/negado).
@_cdecl("ekonami_asb_mic_request")
public func ekonami_asb_mic_request() -> Int32 {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    switch status {
    case .authorized: return 1
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            sem.signal()
        }
        sem.wait()
        return granted ? 1 : 0
    default:
        return 0
    }
}

// MARK: - Session registry

private final class SessionBox: @unchecked Sendable {
    let id: Int32
    let lock = NSLock()
    var transcriber: SpeechTranscriber?
    var analyzer: SpeechAnalyzer?
    var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    var resultsTask: Task<Void, Never>?
    var finalizedText = ""
    var nextBufferTime = CMTime.zero
    var analyzerFormat: AVAudioFormat?
    var converter: AVAudioConverter?
    var sourceFormat: AVAudioFormat?
    var callback: EkonamiAsbChunkCb?
    var userData: UnsafeMutableRawPointer?
    var cancelled = false

    init(id: Int32) { self.id = id }

    func emit(_ text: String, kind: Int32) {
        guard let callback else { return }
        text.withCString { cstr in
            callback(userData, cstr, kind)
        }
    }
}

private final class Registry {
    static let shared = Registry()
    private let lock = NSLock()
    private var nextID: Int32 = 1
    private var sessions: [Int32: SessionBox] = [:]

    func alloc() -> SessionBox {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        let box = SessionBox(id: id)
        sessions[id] = box
        return box
    }

    func get(_ id: Int32) -> SessionBox? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    func remove(_ id: Int32) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: id)
    }
}

/// Inicia sessão. `locale` BCP-47 (ex. "pt-BR"); `bias_csv` frases separadas por vírgula.
/// Retorna handle >0 ou código negativo.
@_cdecl("ekonami_asb_session_start")
public func ekonami_asb_session_start(
    locale: UnsafePointer<CChar>?,
    bias_csv: UnsafePointer<CChar>?,
    callback: EkonamiAsbChunkCb?,
    user_data: UnsafeMutableRawPointer?
) -> Int32 {
    guard SpeechTranscriber.isAvailable else { return -1 }
    guard let callback else { return -2 }

    let localeID = locale.map { String(cString: $0) } ?? "en-US"
    let bias = bias_csv.map { String(cString: $0) } ?? ""
    let phrases = bias
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    let box = Registry.shared.alloc()
    box.callback = callback
    box.userData = user_data

    let sem = DispatchSemaphore(value: 0)
    var startError: String?

    Task {
        do {
            let requested = Locale(identifier: localeID)
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
                ?? Locale(identifier: "en-US")

            let transcriber = SpeechTranscriber(
                locale: resolved,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            box.transcriber = transcriber
            try await ensureModelInstalled(for: transcriber)

            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            box.analyzerFormat = format
            // Fonte fixa do core Rust: f32 mono 16 kHz.
            box.sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
            if let format, let source = box.sourceFormat, format != source {
                box.converter = AVAudioConverter(from: source, to: format)
            }

            let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            box.inputContinuation = inputContinuation

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            box.analyzer = analyzer

            if !phrases.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = phrases
                try? await analyzer.setContext(context)
            }

            if let format {
                try await analyzer.prepareToAnalyze(in: format)
            }

            box.finalizedText = ""
            box.nextBufferTime = .zero

            box.resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        if box.cancelled { break }
                        let snapshot = absorb(result, into: box)
                        if !snapshot.isEmpty {
                            let kind = result.isFinal ? ChunkKind.finalChunk : ChunkKind.partial
                            box.emit(snapshot, kind: kind)
                        }
                    }
                    let final = box.finalizedText.trimmingCharacters(in: .whitespaces)
                    if !final.isEmpty {
                        box.emit(final, kind: ChunkKind.finalChunk)
                    }
                    box.emit("", kind: ChunkKind.ended)
                } catch {
                    if !box.cancelled {
                        box.emit(error.localizedDescription, kind: ChunkKind.error)
                    }
                    box.emit("", kind: ChunkKind.ended)
                }
            }

            try await analyzer.start(inputSequence: inputStream)
        } catch {
            startError = error.localizedDescription
            box.resultsTask?.cancel()
            box.inputContinuation?.finish()
            box.inputContinuation = nil
            box.analyzer = nil
            box.transcriber = nil
        }
        sem.signal()
    }

    sem.wait()

    if let startError {
        box.emit(startError, kind: ChunkKind.error)
        Registry.shared.remove(box.id)
        return -3
    }
    return box.id
}

@_cdecl("ekonami_asb_session_feed")
public func ekonami_asb_session_feed(
    session: Int32,
    samples: UnsafePointer<Float>?,
    count: Int32
) -> Int32 {
    guard count > 0, let samples else { return 0 }
    guard let box = Registry.shared.get(session), !box.cancelled else { return -1 }
    guard let sourceFormat = box.sourceFormat else { return -2 }

    let frameCount = AVAudioFrameCount(count)
    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
    else { return -3 }
    sourceBuffer.frameLength = frameCount
    if let channel = sourceBuffer.floatChannelData?[0] {
        channel.update(from: samples, count: Int(count))
    }

    let buffer: AVAudioPCMBuffer
    if let converter = box.converter, let outFormat = box.analyzerFormat {
        let ratio = outFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(count) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
        else { return -4 }
        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        if converted.frameLength == 0 { return 0 }
        buffer = converted
    } else {
        buffer = sourceBuffer
    }

    box.lock.lock()
    let start = box.nextBufferTime
    let duration = CMTime(
        value: CMTimeValue(buffer.frameLength),
        timescale: CMTimeScale(max(1, Int32(buffer.format.sampleRate.rounded())))
    )
    box.nextBufferTime = CMTimeAdd(start, duration)
    let cont = box.inputContinuation
    box.lock.unlock()

    cont?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
    return 0
}

/// Finaliza e espera o drain dos results. Bloqueante.
@_cdecl("ekonami_asb_session_finish")
public func ekonami_asb_session_finish(session: Int32) -> Int32 {
    guard let box = Registry.shared.get(session) else { return -1 }

    let sem = DispatchSemaphore(value: 0)
    Task {
        box.inputContinuation?.finish()
        box.inputContinuation = nil
        do {
            try await box.analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            await box.analyzer?.cancelAndFinishNow()
        }
        await box.resultsTask?.value
        box.resultsTask = nil
        box.analyzer = nil
        box.transcriber = nil
        Registry.shared.remove(session)
        sem.signal()
    }
    sem.wait()
    return 0
}

@_cdecl("ekonami_asb_session_cancel")
public func ekonami_asb_session_cancel(session: Int32) -> Int32 {
    guard let box = Registry.shared.get(session) else { return -1 }
    box.cancelled = true

    let sem = DispatchSemaphore(value: 0)
    Task {
        box.inputContinuation?.finish()
        box.inputContinuation = nil
        box.resultsTask?.cancel()
        await box.analyzer?.cancelAndFinishNow()
        box.resultsTask = nil
        box.analyzer = nil
        box.transcriber = nil
        Registry.shared.remove(session)
        sem.signal()
    }
    sem.wait()
    return 0
}

// MARK: - Helpers (espelho do AppleSpeechEngine.swift)

private func absorb(_ result: SpeechTranscriber.Result, into box: SessionBox) -> String {
    let text = String(result.text.characters)
    box.lock.lock()
    defer { box.lock.unlock() }
    if result.isFinal {
        box.finalizedText += text
        return box.finalizedText.trimmingCharacters(in: .whitespaces)
    }
    return (box.finalizedText + text).trimmingCharacters(in: .whitespaces)
}

private func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
    let installed = await SpeechTranscriber.installedLocales
    let selected = transcriber.selectedLocales
    let alreadyThere = selected.allSatisfy { locale in
        installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }
    guard !alreadyThere else { return }
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }
}
