import SwiftUI

struct DashboardView: View {
    let controller: DictationController
    private var settings: AppSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 14) {
                MicCard(controller: controller)
                EngineCard(controller: controller)
                StatsCard()
            }
            .frame(height: 240)
            HStack(spacing: 14) {
                HistoryCard()
                    .frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    DictionaryCard()
                    ControlsCard(controller: controller)
                }
                .frame(width: 320)
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 700)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("C O C H I C H O")
                    .font(Theme.mono(22, .semibold))
                    .foregroundStyle(Theme.ink)
                Text("VOICE → TEXT · 100% LOCAL")
                    .font(Theme.mono(10))
                    .tracking(3)
                    .foregroundStyle(Theme.inkFaint)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusLine)
                    .font(Theme.mono(10, .medium))
                    .tracking(1)
                    .foregroundStyle(Theme.inkDim)
            }
            .padding(.top, 6)
        }
    }

    private var statusColor: Color {
        if case .error = controller.state { return Theme.accent }
        if !controller.hotkeyArmed { return .yellow }
        return controller.state.isActive ? Theme.accent : Theme.ok
    }

    private var statusLine: String {
        if case .error(let message) = controller.state { return message.uppercased() }
        if !controller.hotkeyArmed { return "SEM PERMISSÃO DE ACESSIBILIDADE" }
        switch controller.state {
        case .listening: return "OUVINDO"
        case .starting: return "PREPARANDO"
        case .finishing: return "TRANSCREVENDO"
        default:
            return "PRONTO · \(settings.hotkey.displayName) · \(settings.engine.displayName)"
        }
    }
}

// MARK: - 01 MIC

struct MicCard: View {
    let controller: DictationController
    @State private var levels: [Float] = Array(repeating: 0, count: 40)

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    number: "01", title: "MIC",
                    trailing: stateLabel,
                    trailingColor: controller.state.isActive ? Theme.accent : Theme.inkDim
                )

                Text(displayText)
                    .font(Theme.mono(15))
                    .foregroundStyle(controller.transcript.isEmpty ? Theme.inkFaint : Theme.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)

                // No TimelineView: the Canvas already redraws when `levels` mutates, and a
                // timeline forces 20 fps of redraws even while the app sits idle.
                DotWaveform(levels: levels, idle: !controller.state.isActive)
                    .onChange(of: controller.level) { _, new in
                        levels.append(new)
                        if levels.count > 80 { levels.removeFirst(levels.count - 80) }
                    }
                    .frame(height: 56)

                HStack {
                    Button(controller.state.isActive ? "PARAR" : "GRAVAR") {
                        controller.toggleFromUI()
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))

                    Spacer()

                    Stat(label: "TECLA", value: AppSettings.shared.hotkey.displayName)
                }
            }
        }
    }

    private var stateLabel: String {
        switch controller.state {
        case .idle: "IDLE"
        case .starting: "ARMING"
        case .listening: "REC ●"
        case .finishing: "PROC…"
        case .error: "ERR"
        }
    }

    private var displayText: String {
        if case .error(let message) = controller.state { return message }
        if controller.transcript.isEmpty {
            return controller.state.isActive ? "..." : "Segure a tecla e fale."
        }
        return controller.transcript
    }
}

// MARK: - 02 ENGINE

struct EngineCard: View {
    let controller: DictationController
    private var settings: AppSettings { .shared }

    /// Whisper catalog — seeded with the curated list, replaced by the live Hugging Face
    /// listing (device-compatible models only) once it loads.
    @State private var catalog: [String] = WhisperModels.curated
    @State private var downloadingModel: String?
    @State private var downloadProgress: Double = 0
    @State private var failedModel: String?
    @State private var parakeetDownloading = false
    /// Bumped after a download or delete so the `isDownloaded` disk checks re-run.
    @State private var diskVersion = 0

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(number: "02", title: "ENGINE")

                SegmentPicker(
                    options: [(Engine.apple, "APPLE"), (Engine.parakeet, "PARAKEET"), (Engine.whisper, "WHISPER")],
                    selection: Binding(
                        get: { settings.engine },
                        set: { settings.engine = $0 }
                    )
                )

                switch settings.engine {
                case .apple: appleSection
                case .parakeet: parakeetSection
                case .whisper: whisperSection
                }
            }
        }
        .frame(width: 250)
        .task { catalog = await WhisperModels.availableModels() }
    }

    // MARK: - Apple

    private var appleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            languagePicker
            Spacer()
            statusLine("MODELO DO SISTEMA · NEURAL ENGINE")
        }
    }

    // MARK: - Parakeet

    private var parakeetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VERSÃO")
                .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
            SegmentPicker(
                options: ParakeetVersion.allCases.map { ($0, $0.displayName) },
                selection: Binding(
                    get: { settings.parakeetVersion },
                    set: { settings.parakeetVersion = $0 }
                )
            )
            Text(settings.parakeetVersion == .v3
                 ? "DETECTA O IDIOMA SOZINHO · 25 LÍNGUAS"
                 : "SÓ INGLÊS · UM POUCO MAIS PRECISO EM EN")
                .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.inkFaint)

            Spacer()

            let _ = diskVersion
            if ParakeetModels.isDownloaded(settings.parakeetVersion) {
                statusLine("PARAKEET \(settings.parakeetVersion.rawValue.uppercased()) · LOCAL")
            } else {
                Button(parakeetDownloading ? "BAIXANDO…" : "BAIXAR MODELO (~470 MB)") {
                    parakeetDownloading = true
                    let version = settings.parakeetVersion
                    Task {
                        _ = try? await ParakeetModels.shared.manager(version: version)
                        parakeetDownloading = false
                        diskVersion += 1
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(parakeetDownloading)
            }
        }
    }

    // MARK: - Whisper

    private var whisperSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            languagePicker

            Text("MODELO")
                .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
            ScrollView {
                LazyVStack(spacing: 3) {
                    let _ = diskVersion
                    ForEach(catalog, id: \.self) { model in
                        whisperRow(model)
                    }
                }
            }
        }
    }

    private func whisperRow(_ model: String) -> some View {
        let downloaded = WhisperModels.isDownloaded(model)
        let selected = settings.whisperModel == model

        return HStack(spacing: 6) {
            Text(WhisperModels.displayName(model))
                .font(Theme.mono(9, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : (downloaded ? Theme.ink : Theme.inkDim))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let size = WhisperModels.approximateSize(of: model), !downloaded {
                Text(size)
                    .font(Theme.mono(8))
                    .foregroundStyle(Theme.inkFaint)
            }

            if downloadingModel == model {
                Text("\(Int(downloadProgress * 100))%")
                    .font(Theme.mono(8, .medium)).foregroundStyle(Theme.accent)
            } else if failedModel == model {
                Text("ERRO ↻")
                    .font(Theme.mono(8, .medium)).foregroundStyle(Theme.accent)
            } else if selected {
                Text("✓")
                    .font(Theme.mono(9, .semibold)).foregroundStyle(Theme.accent)
            } else if downloaded {
                Button("×") { delete(model) }
                    .buttonStyle(.plain)
                    .font(Theme.mono(10)).foregroundStyle(Theme.inkFaint)
            } else {
                Text("BAIXAR")
                    .font(Theme.mono(8, .medium)).foregroundStyle(Theme.inkDim)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selected ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { tapped(model, downloaded: downloaded) }
    }

    private func tapped(_ model: String, downloaded: Bool) {
        guard downloadingModel == nil else { return }
        if downloaded {
            settings.whisperModel = model
            return
        }
        failedModel = nil
        downloadingModel = model
        downloadProgress = 0
        Task {
            do {
                try await WhisperModels.shared.download(model) { fraction in
                    Task { @MainActor in downloadProgress = fraction }
                }
                settings.whisperModel = model
            } catch {
                Log.speech.error("Whisper download failed: \(error.localizedDescription)")
                failedModel = model
            }
            downloadingModel = nil
            diskVersion += 1
        }
    }

    private func delete(_ model: String) {
        Task {
            await WhisperModels.shared.delete(model)
            diskVersion += 1
        }
    }

    // MARK: - Shared pieces

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IDIOMA")
                .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
            SegmentPicker(
                options: [(Language.ptBR, "PT-BR"), (Language.enUS, "EN-US")],
                selection: Binding(
                    get: { settings.language },
                    set: { settings.language = $0 }
                )
            )
        }
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.ok).frame(width: 6, height: 6)
            Text(text)
                .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.inkDim)
        }
    }
}

// MARK: - 03 STATS

struct StatsCard: View {
    private var history: HistoryStore { .shared }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(number: "03", title: "STATS")
                HStack(spacing: 16) {
                    DottedRing(
                        value: "\(history.entries.count)",
                        caption: "DITADOS"
                    )
                    .frame(width: 120, height: 120)

                    VStack(alignment: .leading, spacing: 14) {
                        Stat(label: "PALAVRAS", value: "\(history.totalWords)")
                        Stat(label: "ÁUDIO", value: minutes(history.totalSeconds))
                        Stat(
                            label: "HOJE",
                            value: "\(todayCount)",
                            color: todayCount > 0 ? Theme.accent : Theme.ink
                        )
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 280)
    }

    private var todayCount: Int {
        history.entries.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    private func minutes(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.0fs", seconds) : String(format: "%.0fmin", seconds / 60)
    }
}
