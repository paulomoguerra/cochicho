import AppKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    let controller: DictationController
    private var settings: AppSettings { .shared }

    /// Layout-edit mode: tiles show their size picker and become draggable.
    @State private var editingLayout = false
    /// The tile currently mid-drag; nil when no drag is in flight.
    @State private var draggedTile: Tile?
    /// Whether the current drag already live-reordered by hovering a tile — a background
    /// drop then keeps that position instead of jumping to the end.
    @State private var dragDidReorder = false

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
                // The grid itself is a drop target, so a tile can be dropped into empty
                // space (it packs into the earliest hole it fits), not only onto a tile.
                .onDrop(of: [.text], delegate: GridDropDelegate(
                    dragged: $draggedTile, didReorder: $dragDidReorder, settings: settings
                ))
            }
            .padding(20)
        }
        .frame(minWidth: 980, minHeight: 700)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onChange(of: editingLayout) {
            draggedTile = nil
            dragDidReorder = false
        }
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
                // Whole-card drag surface: swallows the content's own controls and inner
                // scroll views so the drag never fights them while arranging.
                .overlay(
                    Color.clear
                        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.accent.opacity(draggedTile == config.tile ? 1 : 0.55), lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    sizePicker(for: config)
                        .padding(8)
                }
                .opacity(draggedTile == config.tile ? 0.35 : 1)
                .onDrag {
                    draggedTile = config.tile
                    dragDidReorder = false
                    return NSItemProvider(object: config.tile.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: TileReorderDelegate(
                    target: config.tile, dragged: $draggedTile,
                    didReorder: $dragDidReorder, settings: settings
                ))
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
                    withAnimation(.spring(duration: 0.3)) {
                        settings.tileLayout[index].size = size
                    }
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
                    Button("PADRÃO") {
                        withAnimation(.spring(duration: 0.3)) { settings.applyDefaultLayout() }
                    }
                    .buttonStyle(PillButtonStyle(prominent: !settings.layoutSourceIsCustom))
                    if settings.hasCustomLayout {
                        Button("MEU") {
                            withAnimation(.spring(duration: 0.3)) { settings.applyCustomLayout() }
                        }
                        .buttonStyle(PillButtonStyle(prominent: settings.layoutSourceIsCustom))
                    }
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

    /// Live reorder: the moment the drag hovers another tile, the dragged tile takes that
    /// slot — the grid shuffles under the cursor, so what you see is what you get.
    private struct TileReorderDelegate: DropDelegate {
        let target: Tile
        @Binding var dragged: Tile?
        @Binding var didReorder: Bool
        let settings: AppSettings

        func dropEntered(info: DropInfo) {
            guard let dragged, dragged != target,
                  let from = settings.tileLayout.firstIndex(where: { $0.tile == dragged }),
                  let to = settings.tileLayout.firstIndex(where: { $0.tile == target })
            else { return }
            didReorder = true
            withAnimation(.spring(duration: 0.3)) {
                settings.tileLayout.move(
                    fromOffsets: IndexSet(integer: from),
                    toOffset: to > from ? to + 1 : to
                )
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            dragged = nil
            return true
        }
    }

    /// Backstop for drops on empty grid space. If the drag never hovered a tile, the
    /// dragged tile moves to the end of the order — first-fit packing then slides it into
    /// the earliest hole it fits, which is the empty region the user aimed at.
    private struct GridDropDelegate: DropDelegate {
        @Binding var dragged: Tile?
        @Binding var didReorder: Bool
        let settings: AppSettings

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            defer { dragged = nil }
            guard let tile = dragged else { return false }
            if !didReorder,
               let from = settings.tileLayout.firstIndex(where: { $0.tile == tile }) {
                withAnimation(.spring(duration: 0.3)) {
                    let item = settings.tileLayout.remove(at: from)
                    settings.tileLayout.append(item)
                }
            }
            return true
        }
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
    private var residence: ModelResidence { .shared }

    /// Whisper catalog — seeded with the curated list, replaced by the live Hugging Face
    /// listing (device-compatible models only) once it loads.
    @State private var catalog: [String] = WhisperModels.curated
    @State private var downloadingModel: String?
    @State private var downloadProgress: Double = 0
    @State private var failedModel: String?
    @State private var parakeetDownloading = false
    /// Measured on-disk bytes per downloaded model; refreshed after download/delete.
    @State private var diskSizes: [String: Int64] = [:]
    /// Measured on-disk bytes per Parakeet version; refreshed with `diskVersion`.
    @State private var parakeetDiskSizes: [ParakeetVersion: Int64] = [:]
    /// BCP-47 ids of the Apple speech locales already installed on the system.
    @State private var installedLocaleIDs: Set<String> = []
    /// Bumped after a download or delete so the `isDownloaded` disk checks re-run.
    @State private var diskVersion = 0
    /// Sub-tile listing everything on disk, toggled by the ↓ pill.
    @State private var showingDownloads = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(number: "02", title: "ENGINE")

                HStack(spacing: 4) {
                    SegmentPicker(
                        options: [(Engine.apple, "APPLE"), (Engine.parakeet, "PARAKEET"), (Engine.whisper, "WHISPER")],
                        selection: Binding(
                            get: { settings.engine },
                            set: { new in
                                showingDownloads = false
                                Task { await ModelResidence.shared.unloadAll() }
                                settings.engine = new
                            }
                        )
                    )
                    if size != .small { downloadsPill }
                }

                if showingDownloads, size != .small {
                    downloadsSection
                } else {
                    if size != .small {
                        Text(engineCaption)
                            .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.inkFaint)
                    }

                    switch settings.engine {
                    case .apple: appleSection
                    case .parakeet: parakeetSection
                    case .whisper: whisperSection
                    }
                }
            }
        }
        .task {
            catalog = await WhisperModels.availableModels()
            await residence.refresh()
        }
        .task(id: diskVersion) { await measureDiskSizes() }
        // Re-check when CARREGAR installs a locale's assets via the warm hold.
        .task(id: residence.appleLoadedLocaleID) {
            installedLocaleIDs = Set(
                await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
            )
        }
    }

    // MARK: - Apple

    private var appleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if size != .small {
                languagePicker
                appleAssetsLine
            }
            Spacer()
            if size.isRoomy { performanceRow }
            if size != .small {
                residenceFooter(diskLabel: "MODELO DO SISTEMA", canLoad: true)
            } else {
                statusLine("MODELO DO SISTEMA · NEURAL ENGINE")
            }
        }
    }

    /// Which locales' speech assets the OS already holds on disk.
    private var appleAssetsLine: some View {
        HStack(spacing: 12) {
            Text("MODELOS")
                .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
            ForEach(Language.allCases, id: \.self) { language in
                let installed = installedLocaleIDs.contains(language.locale.identifier(.bcp47))
                HStack(spacing: 4) {
                    Circle()
                        .fill(installed ? Theme.ok : Color.white.opacity(0.15))
                        .frame(width: 5, height: 5)
                    Text(language.rawValue.uppercased())
                        .font(Theme.mono(8)).tracking(1)
                        .foregroundStyle(installed ? Theme.inkDim : Theme.inkFaint)
                }
            }
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
                    set: { new in
                        let previous = settings.parakeetVersion
                        settings.parakeetVersion = new
                        if previous != new {
                            Task { await ModelResidence.shared.unloadParakeetIfNeeded(keeping: new) }
                        }
                    }
                )
            )
            if size != .small {
                Text(settings.parakeetVersion == .v3
                     ? "DETECTA O IDIOMA SOZINHO · 25 LÍNGUAS"
                     : "SÓ INGLÊS · UM POUCO MAIS PRECISO EM EN")
                    .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.inkFaint)
            }

            Spacer()

            if size.isRoomy { performanceRow }

            let _ = diskVersion
            if ParakeetModels.isDownloaded(settings.parakeetVersion) {
                if size != .small {
                    residenceFooter(
                        diskLabel: parakeetDiskLabel,
                        canLoad: true,
                        showDelete: true
                    )
                    if size.isRoomy { parakeetDiskFooter }
                } else {
                    statusLine("PARAKEET \(settings.parakeetVersion.rawValue.uppercased()) · LOCAL")
                }
            } else {
                Button(parakeetDownloading || residence.phase == .loading
                       ? "BAIXANDO…" : "BAIXAR MODELO (~470 MB)") {
                    parakeetDownloading = true
                    Task {
                        await ModelResidence.shared.loadSelected()
                        parakeetDownloading = false
                        diskVersion += 1
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(parakeetDownloading || residence.isBusy || controller.state.isActive)
            }

            if let fraction = residence.downloadProgress {
                DownloadBar(fraction: fraction)
            }
        }
    }

    // MARK: - Downloads sub-tile

    private var downloadsPill: some View {
        Button("↓") {
            showingDownloads.toggle()
        }
        .buttonStyle(.plain)
        .font(Theme.mono(10, .medium))
        .foregroundStyle(showingDownloads ? Color.black : Theme.inkDim)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(showingDownloads ? Theme.accent : Color.white.opacity(0.06))
        .clipShape(Capsule())
        .help("Modelos baixados")
    }

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let _ = diskVersion
                    downloadGroup("APPLE") {
                        let installed = Language.allCases.filter {
                            installedLocaleIDs.contains($0.locale.identifier(.bcp47))
                        }
                        if installed.isEmpty {
                            downloadRow(name: "NENHUM", detail: nil)
                        } else {
                            ForEach(installed, id: \.self) { language in
                                downloadRow(name: language.rawValue.uppercased(), detail: "SISTEMA")
                            }
                        }
                    }
                    downloadGroup("PARAKEET") {
                        let versions = ParakeetVersion.allCases.filter { ParakeetModels.isDownloaded($0) }
                        if versions.isEmpty {
                            downloadRow(name: "NENHUM", detail: nil)
                        } else {
                            ForEach(versions, id: \.self) { version in
                                downloadRow(
                                    name: version.displayName,
                                    detail: parakeetDiskSizes[version].map(Self.formatBytes),
                                    inRAM: residence.parakeetLoaded == version,
                                    onDelete: { deleteParakeet(version) }
                                )
                            }
                        }
                    }
                    downloadGroup("WHISPER") {
                        let models = catalog.filter { WhisperModels.isDownloaded($0) }
                        if models.isEmpty {
                            downloadRow(name: "NENHUM", detail: nil)
                        } else {
                            ForEach(models, id: \.self) { model in
                                downloadRow(
                                    name: WhisperModels.displayName(model),
                                    detail: diskSizes[model].map(Self.formatBytes),
                                    inRAM: residence.whisperLoaded == model,
                                    onDelete: { delete(model) }
                                )
                            }
                        }
                    }
                }
            }
            HStack {
                let total = diskSizes.values.reduce(0, +) + parakeetDiskSizes.values.reduce(0, +)
                statusLine("TOTAL EM DISCO: \(Self.formatBytes(total))", color: Theme.inkDim)
                Spacer()
                finderButton(WhisperModels.downloadBase)
            }
        }
    }

    private func downloadGroup(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
            rows()
        }
    }

    private func downloadRow(
        name: String,
        detail: String?,
        inRAM: Bool = false,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(Theme.mono(9, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(Theme.mono(8)).foregroundStyle(Theme.inkFaint)
            }
            if inRAM {
                Text("RAM")
                    .font(Theme.mono(8, .semibold)).foregroundStyle(Theme.ok)
            }
            if let onDelete {
                Button("×", action: onDelete)
                    .buttonStyle(.plain)
                    .font(Theme.mono(10)).foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func deleteParakeet(_ version: ParakeetVersion) {
        Task {
            await ParakeetModels.shared.delete(version)
            diskVersion += 1
            await ModelResidence.shared.refresh()
        }
    }

    private var parakeetDiskLabel: String {
        let base = "PARAKEET \(settings.parakeetVersion.rawValue.uppercased())"
        guard let bytes = parakeetDiskSizes[settings.parakeetVersion], bytes > 0 else { return base }
        return "\(base) · \(Self.formatBytes(bytes))"
    }

    private var parakeetDiskFooter: some View {
        HStack {
            let total = parakeetDiskSizes.values.reduce(0, +)
            statusLine("USO EM DISCO: \(Self.formatBytes(total))", color: Theme.inkDim)
            Spacer()
            finderButton(ParakeetModels.cacheFolder(settings.parakeetVersion))
        }
    }

    private var parakeetDeleteButton: some View {
        Button("EXCLUIR") { deleteParakeet(settings.parakeetVersion) }
            .buttonStyle(.plain)
            .font(Theme.mono(8, .medium)).tracking(1)
            .foregroundStyle(Theme.inkFaint)
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
                if size.isRoomy { performanceRow }
                residenceFooter(
                    diskLabel: WhisperModels.displayName(settings.whisperModel),
                    canLoad: WhisperModels.isDownloaded(settings.whisperModel)
                )
                if size.isRoomy {
                    diskUsageFooter
                }
            }
        }
    }

    private func whisperRow(_ model: String) -> some View {
        let downloaded = WhisperModels.isDownloaded(model)
        let selected = settings.whisperModel == model
        let inRAM = residence.whisperLoaded == model

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
                DownloadBar(fraction: downloadProgress)
                    .frame(width: 48)
                Text("\(Int(downloadProgress * 100))%")
                    .font(Theme.mono(8, .medium)).foregroundStyle(Theme.accent)
            } else if failedModel == model {
                Text("ERRO ↻")
                    .font(Theme.mono(8, .medium)).foregroundStyle(Theme.accent)
            } else {
                if inRAM {
                    Text("RAM")
                        .font(Theme.mono(8, .semibold)).foregroundStyle(Theme.ok)
                } else if selected {
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
            statusLine("USO EM DISCO: \(Self.formatBytes(total))", color: Theme.inkDim)
            Spacer()
            finderButton(WhisperModels.downloadBase)
        }
    }

    private func tapped(_ model: String, downloaded: Bool) {
        guard downloadingModel == nil else { return }
        if downloaded {
            let previous = settings.whisperModel
            settings.whisperModel = model
            if previous != model {
                Task { await ModelResidence.shared.unloadWhisperIfNeeded(keeping: model) }
            }
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
                let previous = settings.whisperModel
                settings.whisperModel = model
                if previous != model {
                    await ModelResidence.shared.unloadWhisperIfNeeded(keeping: model)
                }
            } catch {
                Log.speech.error("Whisper download failed: \(error.localizedDescription)")
                failedModel = model
            }
            downloadingModel = nil
            diskVersion += 1
            await ModelResidence.shared.refresh()
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
            await ModelResidence.shared.refresh()
        }
    }

    private func measureDiskSizes() async {
        let models = catalog.filter { WhisperModels.isDownloaded($0) }
        diskSizes = await withTaskGroup(of: (String, Int64).self) { group in
            for model in models {
                group.addTask { (model, await WhisperModels.diskSize(of: model)) }
            }
            var sizes: [String: Int64] = [:]
            for await (model, bytes) in group { sizes[model] = bytes }
            return sizes
        }

        var parakeet: [ParakeetVersion: Int64] = [:]
        for version in ParakeetVersion.allCases where ParakeetModels.isDownloaded(version) {
            parakeet[version] = await ParakeetModels.diskSize(of: version)
        }
        parakeetDiskSizes = parakeet
    }

    // MARK: - Performance & shared chrome

    private var engineCaption: String {
        switch settings.engine {
        case .apple: "STREAMING · TEXTO AO VIVO NO HUD"
        case .parakeet: "LOTE · TRANSCREVE AO SOLTAR · NEURAL ENGINE"
        case .whisper: "LOTE · CATÁLOGO OPENAI · COREML"
        }
    }

    /// Latency of the selected engine, measured from its own last 50 history entries.
    private var performance: (last: Double, average: Double, speed: Double?)? {
        let name = settings.engine.displayName
        let recent = HistoryStore.shared.entries.filter { $0.engine == name }.prefix(50)
        guard let latest = recent.first else { return nil }
        let proc = recent.reduce(0.0) { $0 + $1.processSeconds }
        let audio = recent.reduce(0.0) { $0 + $1.audioSeconds }
        return (
            last: latest.processSeconds,
            average: proc / Double(recent.count),
            speed: proc > 0 ? audio / proc : nil
        )
    }

    @ViewBuilder
    private var performanceRow: some View {
        if let perf = performance {
            HStack(alignment: .top, spacing: 16) {
                Stat(label: "ÚLTIMA", value: procText(perf.last), compact: true)
                Stat(label: "MÉDIA", value: procText(perf.average), compact: true)
                if let speed = perf.speed {
                    Stat(
                        label: "VELOCIDADE",
                        value: String(format: speed >= 10 ? "%.0f× REAL" : "%.1f× REAL", speed),
                        compact: true
                    )
                }
            }
        }
    }

    private func procText(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.2fs", seconds) : String(format: "%.1fs", seconds)
    }

    private func finderButton(_ folder: URL) -> some View {
        Button("FINDER") {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
        .buttonStyle(.plain)
        .font(Theme.mono(8, .medium)).tracking(1)
        .foregroundStyle(Theme.inkFaint)
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
                    set: { new in
                        let previous = settings.language
                        settings.language = new
                        if previous != new, settings.engine == .apple {
                            Task { await ModelResidence.shared.unloadAppleIfNeeded(keeping: new) }
                        }
                    }
                )
            )
        }
    }

    /// Disk vs RAM status + CARREGAR / DESCARREGAR for the selected engine model.
    private func residenceFooter(
        diskLabel: String,
        canLoad: Bool,
        showDelete: Bool = false
    ) -> some View {
        let inRAM = residence.isSelectedInRAM(settings: settings)
        let busy = residence.isBusy || controller.state.isActive
        let loading = residence.phase == .loading

        return HStack(spacing: 8) {
            if loading {
                statusLine("CARREGANDO…", color: Theme.accent)
            } else if inRAM {
                statusLine("EM RAM", color: Theme.ok)
            } else if canLoad {
                statusLine("\(diskLabel) · NO DISCO", color: Theme.inkDim)
            } else {
                statusLine(diskLabel, color: Theme.inkDim)
            }

            Spacer(minLength: 4)

            if loading {
                EmptyView()
            } else if inRAM {
                Button("DESCARREGAR") {
                    Task { await ModelResidence.shared.unloadSelected() }
                }
                .buttonStyle(.plain)
                .font(Theme.mono(8, .medium)).tracking(1)
                .foregroundStyle(Theme.inkFaint)
                .disabled(busy)
            } else if canLoad {
                Button("CARREGAR") {
                    Task { await ModelResidence.shared.loadSelected() }
                }
                .buttonStyle(.plain)
                .font(Theme.mono(8, .medium)).tracking(1)
                .foregroundStyle(Theme.accent)
                .disabled(busy)
            }

            if showDelete {
                parakeetDeleteButton
            }
        }
    }

    private func statusLine(_ text: String, color: Color = Theme.ok) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.inkDim)
        }
    }
}

// MARK: - 03 STATS

struct StatsCard: View {
    var size: TileSize = .small
    private var history: HistoryStore { .shared }
    private var compact: Bool { !size.isRoomy }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                CardHeader(number: "03", title: "STATS")
                HStack(alignment: .top, spacing: compact ? 10 : 16) {
                    DottedRing(
                        value: "\(history.entries.count)",
                        caption: "DITADOS"
                    )
                    .frame(
                        width: compact ? 86 : 120,
                        height: compact ? 86 : 120
                    )

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                        alignment: .leading,
                        spacing: compact ? 6 : 10
                    ) {
                        Stat(label: "PALAVRAS", value: "\(history.totalWords)", compact: compact)
                        Stat(label: "ÁUDIO", value: minutes(history.totalSeconds), compact: compact)
                        Stat(
                            label: "HOJE",
                            value: "\(todayCount)",
                            color: todayCount > 0 ? Theme.accent : Theme.ink,
                            compact: compact
                        )
                        Stat(label: "SEMANA", value: "\(weekCount)", compact: compact)
                        Stat(label: "MÉDIA", value: averageWordsDisplay, compact: compact)
                        Stat(label: "PROC", value: averageProcess, compact: compact)
                        Stat(label: "CORREÇÕES", value: "\(totalCorrections)", compact: compact)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var todayCount: Int {
        history.entries.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    private var weekCount: Int {
        let cal = Calendar.current
        let now = Date()
        return history.entries.filter {
            cal.isDate($0.date, equalTo: now, toGranularity: .weekOfYear)
        }.count
    }

    private var averageWordsDisplay: String {
        guard !history.entries.isEmpty else { return "—" }
        return "\(history.totalWords / history.entries.count)W"
    }

    private var averageProcess: String {
        guard !history.entries.isEmpty else { return "—" }
        let total = history.entries.reduce(0) { $0 + $1.processSeconds }
        return String(format: "%.1fs", total / Double(history.entries.count))
    }

    private var totalCorrections: Int {
        history.entries.reduce(0) { $0 + ($1.corrections?.count ?? 0) }
    }

    private func minutes(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.0fs", seconds) : String(format: "%.0fmin", seconds / 60)
    }
}
