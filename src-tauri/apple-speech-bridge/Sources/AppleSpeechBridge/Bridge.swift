import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import Foundation
import Speech

/// C ABI entre o core Rust e o Speech framework (Swift-only).
///
/// ABI v4 — sessão streaming + warm hold + captura nativa de hotkey:
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
    4
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
    var finalizedSegments: [(range: CMTimeRange, text: String)] = []
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

            box.finalizedSegments = []
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

// MARK: - Warm hold manual

private actor WarmHold {
    static let shared = WarmHold()

    private var held: (localeID: String, analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber)?

    func load(localeID: String) async throws {
        let requested = Locale(identifier: localeID)
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
            ?? Locale(identifier: "en-US")
        if let held,
           Locale(identifier: held.localeID).identifier(.bcp47)
            == resolved.identifier(.bcp47) {
            return
        }

        await unload()
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        try await ensureModelInstalled(for: transcriber)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else {
            throw NSError(
                domain: "AppleSpeechBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "formato de áudio indisponível"]
            )
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        held = (resolved.identifier, analyzer, transcriber)
    }

    func unload() async {
        if let held {
            await held.analyzer.cancelAndFinishNow()
        }
        held = nil
    }
}

@_cdecl("ekonami_asb_warm_load")
public func ekonami_asb_warm_load(locale: UnsafePointer<CChar>?) -> Int32 {
    guard SpeechTranscriber.isAvailable else { return -1 }
    let localeID = locale.map { String(cString: $0) } ?? "en-US"
    let sem = DispatchSemaphore(value: 0)
    var result: Int32 = 0
    Task {
        do {
            try await WarmHold.shared.load(localeID: localeID)
        } catch {
            result = -2
        }
        sem.signal()
    }
    sem.wait()
    return result
}

@_cdecl("ekonami_asb_warm_unload")
public func ekonami_asb_warm_unload() -> Int32 {
    let sem = DispatchSemaphore(value: 0)
    Task {
        await WarmHold.shared.unload()
        sem.signal()
    }
    sem.wait()
    return 0
}

// MARK: - Original menu bar symbols

private final class MenuBarIconStore: @unchecked Sendable {
    static let shared = MenuBarIconStore()
    let lock = NSLock()
    var idle: Data?
    var active: Data?
}

private func renderMenuBarSymbol(active: Bool) -> Data? {
    let name = active ? "waveform.circle.fill" : "waveform"
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Eko Nami") else {
        return nil
    }
    let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    let symbol = base.withSymbolConfiguration(configuration) ?? base
    let canvas = NSImage(size: NSSize(width: 20, height: 20))
    canvas.lockFocus()
    NSColor.black.set()
    let fitted = NSRect(x: 1, y: 1, width: 18, height: 18)
    symbol.draw(in: fitted)
    canvas.unlockFocus()
    guard let tiff = canvas.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}

@_cdecl("ekonami_asb_menubar_icon_png")
public func ekonami_asb_menubar_icon_png(
    active: Int32,
    length: UnsafeMutablePointer<Int>?
) -> UnsafePointer<UInt8>? {
    let isActive = active != 0
    let store = MenuBarIconStore.shared
    store.lock.lock()
    defer { store.lock.unlock() }

    if isActive, store.active == nil {
        store.active = renderMenuBarSymbol(active: true)
    } else if !isActive, store.idle == nil {
        store.idle = renderMenuBarSymbol(active: false)
    }
    guard let data = isActive ? store.active : store.idle else { return nil }
    length?.pointee = data.count
    return data.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress }
}

// MARK: - Native one-shot hotkey capture

private final class HotkeyCaptureSession: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var monitor: Any?
    var keyCode: Int64 = -1
    var modifierFlag: UInt64 = 0
    var displayName = ""
    var finished = false

    func complete(keyCode: Int64, modifierFlag: UInt64, displayName: String) {
        guard !finished else { return }
        finished = true
        self.keyCode = keyCode
        self.modifierFlag = modifierFlag
        self.displayName = displayName
        removeMonitor()
        semaphore.signal()
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        removeMonitor()
        semaphore.signal()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private final class HotkeyCaptureStore: @unchecked Sendable {
    static let shared = HotkeyCaptureStore()
    let lock = NSLock()
    var current: HotkeyCaptureSession?
}

private func hotkeySpec(from event: NSEvent) -> (Int64, UInt64, String)? {
    let code = Int64(event.keyCode)
    if event.type == .flagsChanged {
        switch code {
        case Int64(kVK_Control): return (code, 0x01, "L⌃")
        case Int64(kVK_Shift): return (code, 0x02, "L⇧")
        case Int64(kVK_RightShift): return (code, 0x04, "R⇧")
        case Int64(kVK_Command): return (code, 0x08, "L⌘")
        case Int64(kVK_RightCommand): return (code, 0x10, "R⌘")
        case Int64(kVK_Option): return (code, 0x20, "L⌥")
        case Int64(kVK_RightOption): return (code, 0x40, "R⌥")
        case Int64(kVK_RightControl): return (code, 0x2000, "R⌃")
        case Int64(kVK_Function):
            return (code, UInt64(CGEventFlags.maskSecondaryFn.rawValue), "FN")
        default: return nil
        }
    }
    guard event.type == .keyDown, !event.isARepeat else { return nil }
    let names: [UInt16: String] = [
        UInt16(kVK_Return): "RETURN", UInt16(kVK_Tab): "TAB",
        UInt16(kVK_Space): "SPACE", UInt16(kVK_Delete): "DELETE",
        UInt16(kVK_Escape): "ESC", UInt16(kVK_CapsLock): "CAPS",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20"
    ]
    let name = names[event.keyCode]
        ?? event.charactersIgnoringModifiers?.uppercased()
        ?? "KEY \(event.keyCode)"
    return (code, 0, name)
}

@_cdecl("ekonami_asb_hotkey_capture")
public func ekonami_asb_hotkey_capture(
    keyCode: UnsafeMutablePointer<Int64>?,
    modifierFlag: UnsafeMutablePointer<UInt64>?,
    displayName: UnsafeMutablePointer<CChar>?,
    displayCapacity: Int32
) -> Int32 {
    let session = HotkeyCaptureSession()
    let store = HotkeyCaptureStore.shared
    store.lock.lock()
    store.current?.cancel()
    store.current = session
    store.lock.unlock()

    DispatchQueue.main.async {
        guard !session.finished else { return }
        session.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { event in
            guard let spec = hotkeySpec(from: event) else { return event }
            session.complete(
                keyCode: spec.0,
                modifierFlag: spec.1,
                displayName: spec.2
            )
            return nil
        }
    }

    session.semaphore.wait()
    store.lock.lock()
    if store.current === session { store.current = nil }
    store.lock.unlock()
    guard session.keyCode >= 0 else { return 1 }
    keyCode?.pointee = session.keyCode
    modifierFlag?.pointee = session.modifierFlag
    if let displayName, displayCapacity > 0 {
        let bytes = Array(session.displayName.utf8.prefix(Int(displayCapacity) - 1))
        for (index, byte) in bytes.enumerated() {
            displayName[index] = CChar(bitPattern: byte)
        }
        displayName[bytes.count] = 0
    }
    return 0
}

@_cdecl("ekonami_asb_hotkey_capture_cancel")
public func ekonami_asb_hotkey_capture_cancel() {
    let store = HotkeyCaptureStore.shared
    store.lock.lock()
    let session = store.current
    store.lock.unlock()
    if Thread.isMainThread {
        session?.cancel()
    } else {
        DispatchQueue.main.sync { session?.cancel() }
    }
}

// MARK: - Helpers (espelho do AppleSpeechEngine.swift)

private func absorb(_ result: SpeechTranscriber.Result, into box: SessionBox) -> String {
    let text = String(result.text.characters)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }
    box.lock.lock()
    defer { box.lock.unlock() }

    if result.isFinal {
        box.finalizedSegments.removeAll { rangesOverlap($0.range, result.range) }
        box.finalizedSegments.append((result.range, text))
    }

    var snapshot = box.finalizedSegments
    if !result.isFinal {
        snapshot.removeAll { rangesOverlap($0.range, result.range) }
        snapshot.append((result.range, text))
    }
    snapshot.sort { CMTimeCompare($0.range.start, $1.range.start) < 0 }
    return joinTranscript(snapshot.map(\.text))
}

private func rangesOverlap(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Bool {
    if CMTimeCompare(lhs.start, rhs.start) == 0 { return true }
    return CMTimeCompare(lhs.start, CMTimeRangeGetEnd(rhs)) < 0
        && CMTimeCompare(rhs.start, CMTimeRangeGetEnd(lhs)) < 0
}

private func joinTranscript(_ pieces: [String]) -> String {
    pieces.reduce(into: "") { result, raw in
        let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        guard !result.isEmpty else {
            result = piece
            return
        }
        let punctuation = CharacterSet(charactersIn: ".,!?;:")
        let startsWithPunctuation = piece.unicodeScalars.first
            .map { punctuation.contains($0) } ?? false
        if !result.hasSuffix(" ") && !startsWithPunctuation { result.append(" ") }
        result.append(piece)
    }
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
