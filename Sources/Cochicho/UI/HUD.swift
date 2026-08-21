import AppKit
import SwiftUI

/// The floating capsule shown while dictating.
///
/// The single most important property: this panel **never becomes key**. If it did, the
/// user's text field would lose focus and `TextInjector` would have nothing to insert
/// into. Hence `.nonactivatingPanel` plus `canBecomeKey == false`.
@MainActor
final class HUDPanel: NSPanel {
    init(controller: DictationController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 84),
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

        contentView = NSHostingView(rootView: HUDView(controller: controller))
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
        let size = frame.size
        setFrameOrigin(
            NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 96)
        )
    }

    func present() {
        // Every active state change (starting → listening → finishing) calls this; without
        // the early exit the panel re-fades on each one, which reads as a flicker.
        guard !isVisible || alphaValue < 1 else { return }

        reposition()
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
    let controller: DictationController
    @State private var levels: [Float] = Array(repeating: 0, count: 40)

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(controller.state == .finishing ? Theme.ink : Theme.accent)
                    .frame(width: 7, height: 7)

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

            DotWaveform(levels: levels, columns: 44, rows: 5)
                .frame(height: 26)
                .onChange(of: controller.level) { _, new in
                    levels.append(new)
                    if levels.count > 88 { levels.removeFirst(levels.count - 88) }
                }

            if !controller.transcript.isEmpty {
                Text(controller.transcript)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.card.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
        .padding(6)
    }

    private var label: String {
        switch controller.state {
        case .starting: "PREPARANDO"
        case .listening: "OUVINDO"
        case .finishing: "TRANSCREVENDO"
        default: ""
        }
    }
}
