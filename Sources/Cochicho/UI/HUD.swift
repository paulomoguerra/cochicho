import AppKit
import SwiftUI

/// The floating capsule shown while dictating.
///
/// The single most important property: this panel **never becomes key**. If it did, the
/// user's text field would lose focus and `TextInjector` would have nothing to insert
/// into. Hence `.nonactivatingPanel` plus `canBecomeKey == false`.
@MainActor
final class HUDPanel: NSPanel {
    private let hosting: NSHostingView<HUDView>

    init(controller: DictationController) {
        let size = AppSettings.shared.hudSize.panelSize
        let hosting = NSHostingView(rootView: HUDView(controller: controller))
        hosting.autoresizingMask = [.width, .height]
        self.hosting = hosting

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        hosting.frame = CGRect(origin: .zero, size: size)
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Parks the panel just above the Dock, centered on the active screen.
    ///
    /// `NSScreen.main` is the screen with the *key window* — and an accessory app with a
    /// non-activating panel never has one, so it can be nil.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = AppSettings.shared.hudSize.panelSize
        setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.minY + 96,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        hosting.frame = CGRect(origin: .zero, size: size)
    }

    func applySize() {
        reposition()
    }

    func present() {
        // Every active state change (starting → listening → finishing) calls this; without
        // the early exit the panel re-fades on each one, which reads as a flicker.
        applySize()
        guard !isVisible || alphaValue < 1 else { return }

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread.
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }
}

struct HUDView: View {
    @Bindable var controller: DictationController
    @State private var levels: [Float] = Array(repeating: 0, count: 40)

    private var settings: AppSettings { .shared }

    var body: some View {
        Group {
            switch settings.hudSize {
            case .minimal: minimalBody
            case .medium: mediumBody
            case .large: largeBody
            }
        }
        .onChange(of: controller.level) { _, new in
            levels.append(new)
            if levels.count > 88 { levels.removeFirst(levels.count - 88) }
        }
    }

    /// Former "padrão" — header, waveform, one live transcript line.
    private var mediumBody: some View {
        VStack(spacing: 6) {
            chromeHeader
            wave(columns: 44, rows: 5, height: 26)
            liveTranscript(fontSize: 10, lines: 1, minHeight: 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(cardBackground(radius: 16))
        .padding(6)
    }

    /// Larger card. Transcript sits *above* the waveform with reserved height so live
    /// updates can't be clipped away by the Canvas (the failure mode of the first Grande).
    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            chromeHeader
            liveTranscript(fontSize: 13, lines: 3, minHeight: 54)
            wave(columns: 52, rows: 7, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground(radius: 16))
        .padding(6)
    }

    /// Pill: status dot + short waveform. No brand, no status label, no transcript.
    private var minimalBody: some View {
        HStack(spacing: 8) {
            statusDot
            wave(columns: 20, rows: 5, height: 16)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(cardBackground(capsule: true))
        .padding(4)
    }

    // MARK: - Shared pieces

    /// Always on while dictating (placeholder `…`) so the Text node exists before the
    /// first chunk arrives and keeps updating as `controller.transcript` streams.
    private func liveTranscript(fontSize: CGFloat, lines: Int, minHeight: CGFloat) -> some View {
        let text = controller.transcript
        let shown: String = {
            if !text.isEmpty { return text }
            if controller.state.isActive { return "…" }
            return ""
        }()

        return Text(shown)
            .font(Theme.mono(fontSize))
            .foregroundStyle(text.isEmpty ? Theme.inkFaint : Theme.ink)
            .lineLimit(lines)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .opacity(shown.isEmpty ? 0 : 1)
            .accessibilityLabel(text)
    }

    private func wave(columns: Int, rows: Int, height: CGFloat) -> some View {
        DotWaveform(levels: levels, columns: columns, rows: rows)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
    }

    private var chromeHeader: some View {
        HStack(spacing: 10) {
            statusDot

            Text(label)
                .font(Theme.mono(10, .medium))
                .tracking(2)
                .foregroundStyle(Theme.inkDim)

            Spacer()

            Text("COCHICHO")
                .font(Theme.mono(8, .medium))
                .tracking(2)
                .foregroundStyle(Theme.inkFaint)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(controller.state == .finishing ? Theme.ink : Theme.accent)
            .frame(width: 7, height: 7)
    }

    private var label: String {
        switch controller.state {
        case .starting: "PREPARANDO"
        case .listening: "OUVINDO"
        case .finishing: "TRANSCREVENDO"
        default: ""
        }
    }

    @ViewBuilder
    private func cardBackground(radius: CGFloat = 16, capsule: Bool = false) -> some View {
        if capsule {
            Theme.card.opacity(0.96)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.cardBorder, lineWidth: 1))
        } else {
            Theme.card.opacity(0.96)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Theme.cardBorder, lineWidth: 1)
                )
        }
    }
}
