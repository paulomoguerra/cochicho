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

                TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
                    DotWaveform(levels: levels, idle: !controller.state.isActive)
                        .onChange(of: controller.level) { _, new in
                            levels.append(new)
                            if levels.count > 80 { levels.removeFirst(levels.count - 80) }
                        }
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
    @State private var parakeetReady = ParakeetModels.isDownloaded
    @State private var downloading = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(number: "02", title: "ENGINE")

                VStack(alignment: .leading, spacing: 8) {
                    Text("MODELO")
                        .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
                    SegmentPicker(
                        options: [(Engine.apple, "APPLE"), (Engine.parakeet, "PARAKEET")],
                        selection: Binding(
                            get: { settings.engine },
                            set: { settings.engine = $0 }
                        )
                    )
                }

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
                    if settings.engine == .parakeet {
                        Text("PARAKEET DETECTA O IDIOMA SOZINHO")
                            .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.inkFaint)
                    }
                }

                Spacer()

                if settings.engine == .parakeet && !parakeetReady {
                    Button(downloading ? "BAIXANDO…" : "BAIXAR MODELO (~470 MB)") {
                        downloading = true
                        Task {
                            _ = try? await ParakeetModels.shared.manager()
                            parakeetReady = ParakeetModels.isDownloaded
                            downloading = false
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(downloading)
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.ok).frame(width: 6, height: 6)
                        Text(settings.engine == .apple
                             ? "MODELO DO SISTEMA · NEURAL ENGINE"
                             : "PARAKEET V3 · HUGGING FACE · LOCAL")
                            .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.inkDim)
                    }
                }
            }
        }
        .frame(width: 250)
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
