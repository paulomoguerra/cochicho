import SwiftUI

struct DashboardView: View {
    let controller: DictationController
    private var settings: AppSettings { .shared }

    /// Layout-edit mode: tiles show their size picker and become draggable.
    @State private var editingLayout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                BentoLayout(spacing: 14) {
                    ForEach(settings.tileLayout) { config in
                        tileView(config)
                            .tileSpan(config.size)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 980, minHeight: 700)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func tileView(_ config: TileConfig) -> some View {
        let card = Group {
            switch config.tile {
            case .mic: MicCard(controller: controller, size: config.size)
            case .engine: EngineCard(controller: controller, size: config.size)
            case .stats: StatsCard(size: config.size)
            case .history: HistoryCard(size: config.size)
            case .dictionary: DictionaryCard(size: config.size)
            case .controls: ControlsCard(controller: controller, size: config.size)
            }
        }

        if editingLayout {
            card
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.accent.opacity(0.55), lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    sizePicker(for: config)
                        .padding(8)
                }
                .draggable(config.tile.rawValue)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let dragged = Tile(rawValue: raw) else { return false }
                    move(dragged, onto: config.tile)
                    return true
                }
        } else {
            card
        }
    }

    private func sizePicker(for config: TileConfig) -> some View {
        HStack(spacing: 3) {
            ForEach(TileSize.allCases, id: \.self) { size in
                Button(size.label) {
                    guard let index = settings.tileLayout.firstIndex(where: { $0.tile == config.tile })
                    else { return }
                    settings.tileLayout[index].size = size
                }
                .buttonStyle(.plain)
                .font(Theme.mono(9, .semibold))
                .foregroundStyle(config.size == size ? Color.black : Theme.inkDim)
                .frame(width: 20, height: 20)
                .background(config.size == size ? Theme.accent : Theme.card.opacity(0.9))
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 1))
            }
        }
    }

    /// Drop = take the target tile's slot; everything else shifts around it.
    private func move(_ dragged: Tile, onto target: Tile) {
        var layout = settings.tileLayout
        guard let from = layout.firstIndex(where: { $0.tile == dragged }),
              let to = layout.firstIndex(where: { $0.tile == target }),
              from != to else { return }
        let item = layout.remove(at: from)
        layout.insert(item, at: to)
        settings.tileLayout = layout
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
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusLine)
                        .font(Theme.mono(10, .medium))
                        .tracking(1)
                        .foregroundStyle(Theme.inkDim)
                }

                if editingLayout {
                    Button("PADRÃO") { settings.tileLayout = TileConfig.defaultLayout }
                        .buttonStyle(PillButtonStyle())
                }
                Button(editingLayout ? "PRONTO" : "LAYOUT") { editingLayout.toggle() }
                    .buttonStyle(PillButtonStyle(prominent: editingLayout))
            }
            .padding(.top, 2)
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
    var size: TileSize = .wide
    @State private var levels: [Float] = Array(repeating: 0, count: 40)

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    number: "01", title: "MIC",
                    trailing: stateLabel,
                    trailingColor: controller.state.isActive ? Theme.accent : Theme.inkDim
                )

                if size != .small {
                    Text(displayText)
                        .font(Theme.mono(15))
                        .foregroundStyle(controller.transcript.isEmpty ? Theme.inkFaint : Theme.ink)
                        .lineLimit(size.isRoomy ? 5 : 2)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                }

                // No TimelineView: the Canvas already redraws when `levels` mutates, and a
                // timeline forces 20 fps of redraws even while the app sits idle.
                DotWaveform(levels: levels, rows: size.isRoomy ? 9 : 7, idle: !controller.state.isActive)
                    .onChange(of: controller.level) { _, new in
                        levels.append(new)
                        if levels.count > 80 { levels.removeFirst(levels.count - 80) }
                    }
                    .frame(height: size.isRoomy ? 88 : (size == .small ? 44 : 56))
                    .frame(maxHeight: size.isRoomy ? .infinity : nil)

                HStack {
                    Button(controller.state.isActive ? "PARAR" : "GRAVAR") {
                        controller.toggleFromUI()
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))

                    Spacer()

                    if size != .small {
                        Stat(label: "TECLA", value: AppSettings.shared.hotkey.displayName)
                    }
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
    var size: TileSize = .tall
    private var settings: AppSettings { .shared }

    /// Whisper catalog — seeded with the curated list, replaced by the live Hugging Face
    /// listing (device-compatible models only) once it loads.
    @State private var catalog: [String] = WhisperModels.curated
    @State private var downloadingModel: String?
    @State private var downloadProgress: Double = 0
    @State private var failedModel: String?
    @State private var parakeetDownloading = false
    /// Measured on-disk bytes per downloaded model; refreshed after download/delete.
    @State private var diskSizes: [String: Int64] = [:]
    /// Bumped after a download or delete so the `isDownloaded` disk checks re-run.
    @State private var diskVersion = 0

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
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
        .task { catalog = await WhisperModels.availableModels() }
        .task(id: diskVersion) { await measureDiskSizes() }
    }

    // MARK: - Apple

    private var appleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if size != .small { languagePicker }
            Spacer()
            statusLine("MODELO DO SISTEMA · NEURAL ENGINE")
        }
    }

    // MARK: - Parakeet

    private var parakeetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if size != .small {
                Text("VERSÃO")
                    .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
            }
            SegmentPicker(
                options: ParakeetVersion.allCases.map { ($0, $0.displayName) },
                selection: Binding(
                    get: { settings.parakeetVersion },
                    set: { settings.parakeetVersion = $0 }
                )
            )
            if size != .small {
                Text(settings.parakeetVersion == .v3
                     ? "DETECTA O IDIOMA SOZINHO · 25 LÍNGUAS"
                     : "SÓ INGLÊS · UM POUCO MAIS PRECISO EM EN")
                    .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.inkFaint)
            }

            Spacer()

            let _ = diskVersion
            if ParakeetModels.isDownloaded(settings.parakeetVersion) {
                HStack {
                    statusLine("PARAKEET \(settings.parakeetVersion.rawValue.uppercased()) · LOCAL")
                    Spacer()
                    if size.isRoomy {
                        Button("EXCLUIR") {
                            let version = settings.parakeetVersion
                            Task {
                                await ParakeetModels.shared.delete(version)
                                diskVersion += 1
                            }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.mono(8, .medium)).tracking(1)
                        .foregroundStyle(Theme.inkFaint)
                    }
                }
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
            if size != .small { languagePicker }

            if size == .small {
                // Tiny tile: just what's active. Grow the tile to manage the catalog.
                Spacer()
                statusLine(WhisperModels.displayName(settings.whisperModel))
                Text("AUMENTE O TILE PARA GERENCIAR")
                    .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.inkFaint)
            } else {
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
                if size.isRoomy {
                    diskUsageFooter
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

            if downloaded, let bytes = diskSizes[model] {
                Text(Self.formatBytes(bytes))
                    .font(Theme.mono(8))
                    .foregroundStyle(Theme.inkFaint)
            } else if !downloaded, let size = WhisperModels.approximateSize(of: model) {
                Text("~\(size)")
                    .font(Theme.mono(8))
                    .foregroundStyle(Theme.inkFaint)
            }

            if downloadingModel == model {
                Text("\(Int(downloadProgress * 100))%")
                    .font(Theme.mono(8, .medium)).foregroundStyle(Theme.accent)
            } else if failedModel == model {
                Text("ERRO ↻")
                    .font(Theme.mono(8, .medium)).foregroundStyle(Theme.accent)
            } else {
                if selected {
                    Text("✓")
                        .font(Theme.mono(9, .semibold)).foregroundStyle(Theme.accent)
                }
                if downloaded {
                    Button("×") { delete(model) }
                        .buttonStyle(.plain)
                        .font(Theme.mono(10)).foregroundStyle(Theme.inkFaint)
                } else {
                    Text("BAIXAR")
                        .font(Theme.mono(8, .medium)).foregroundStyle(Theme.inkDim)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selected ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { tapped(model, downloaded: downloaded) }
    }

    private var diskUsageFooter: some View {
        let total = diskSizes.values.reduce(0, +)
        return HStack {
            statusLine("USO EM DISCO: \(Self.formatBytes(total))")
            Spacer()
        }
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

    /// Any downloaded model can go, including the selected one — the selection just falls
    /// back to another model on disk (or the default) instead of blocking the delete.
    private func delete(_ model: String) {
        Task {
            await WhisperModels.shared.delete(model)
            if settings.whisperModel == model {
                let remaining = catalog.first { $0 != model && WhisperModels.isDownloaded($0) }
                settings.whisperModel = remaining ?? "openai_whisper-base"
            }
            diskVersion += 1
        }
    }

    private func measureDiskSizes() async {
        let models = catalog.filter { WhisperModels.isDownloaded($0) }
        var sizes: [String: Int64] = [:]
        for model in models {
            sizes[model] = await WhisperModels.diskSize(of: model)
        }
        diskSizes = sizes
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : String(format: "%.0f MB", mb)
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
    var size: TileSize = .small
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
                    .frame(
                        width: size == .small ? 96 : 120,
                        height: size == .small ? 96 : 120
                    )

                    VStack(alignment: .leading, spacing: size == .small ? 10 : 14) {
                        Stat(label: "PALAVRAS", value: "\(history.totalWords)")
                        Stat(label: "ÁUDIO", value: minutes(history.totalSeconds))
                        Stat(
                            label: "HOJE",
                            value: "\(todayCount)",
                            color: todayCount > 0 ? Theme.accent : Theme.ink
                        )
                        if size.isRoomy {
                            Stat(label: "MÉDIA/DITADO", value: "\(averageWords)W")
                            Stat(label: "PROC MÉDIO", value: averageProcess)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var todayCount: Int {
        history.entries.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    private var averageWords: Int {
        history.entries.isEmpty ? 0 : history.totalWords / history.entries.count
    }

    private var averageProcess: String {
        guard !history.entries.isEmpty else { return "—" }
        let total = history.entries.reduce(0) { $0 + $1.processSeconds }
        return String(format: "%.1fs", total / Double(history.entries.count))
    }

    private func minutes(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.0fs", seconds) : String(format: "%.0fmin", seconds / 60)
    }
}
