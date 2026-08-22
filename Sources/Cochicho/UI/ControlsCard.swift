import AppKit
import SwiftUI

// MARK: - 06 CONTROLS

struct ControlsCard: View {
    let controller: DictationController
    var size: TileSize = .tall
    private var settings: AppSettings { .shared }
    @State private var recordingKey = false
    @State private var keyMonitor: Any?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: size.isRoomy ? 8 : 12) {
                CardHeader(number: "06", title: "CONTROLES")

                // Hotkey picker: presets + free capture.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("TECLA DE ATIVAÇÃO")
                            .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
                        Spacer()
                        Text(settings.hotkey.displayName)
                            .font(Theme.mono(11, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    HStack(spacing: 4) {
                        preset("R⌥", .rightOption)
                        preset("R⌘", .rightCommand)
                        preset("FN", .fn)
                        Button(recordingKey ? "APERTE…" : "OUTRA…") {
                            recordingKey ? stopRecording() : startRecording()
                        }
                        .buttonStyle(.plain)
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(recordingKey ? Color.black : Theme.inkDim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(recordingKey ? Theme.accent : Color.white.opacity(0.06))
                        .clipShape(Capsule())
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("MODO")
                        .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
                    SegmentPicker(
                        options: [(HotkeyMode.hold, "SEGURAR"), (HotkeyMode.toggle, "ALTERNAR")],
                        selection: Binding(
                            get: { settings.hotkeyMode },
                            set: {
                                settings.hotkeyMode = $0
                                controller.reloadHotkey()
                            }
                        )
                    )
                }

                if size != .small {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TAMANHO DO HUD")
                            .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
                        SegmentPicker(
                            options: HUDSize.allCases.map { ($0, $0.displayName) },
                            selection: Binding(
                                get: { settings.hudSize },
                                set: { settings.hudSize = $0 }
                            )
                        )
                    }
                }

                if size.isRoomy {
                    Divider().overlay(Theme.cardBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        FlagRow(label: "ÍCONE NA MENUBAR", isOn: menuBarBinding)
                        FlagRow(label: "ÍCONE NO DOCK", isOn: dockBinding)
                        FlagRow(label: "ABRIR AO INICIAR", isOn: launchAtLoginBinding)
                        FlagRow(label: "SONS", isOn: Binding(
                            get: { settings.soundEnabled },
                            set: { settings.soundEnabled = $0 }
                        ))

                        Divider().overlay(Theme.cardBorder)

                        Text("COMPORTAMENTO")
                            .font(Theme.mono(9)).tracking(1.5).foregroundStyle(Theme.inkFaint)
                        FlagRow(label: "CORRIGIR COM DICIONÁRIO", isOn: Binding(
                            get: { settings.dictionaryEnabled },
                            set: { settings.dictionaryEnabled = $0 }
                        ))
                        FlagRow(label: "SALVAR NO HISTÓRICO", isOn: Binding(
                            get: { settings.saveHistory },
                            set: { settings.saveHistory = $0 }
                        ))
                        FlagRow(label: "COPIAR TEXTO", isOn: Binding(
                            get: { settings.copyToClipboard },
                            set: { settings.copyToClipboard = $0 }
                        ))
                        FlagRow(label: "ENTER AO INSERIR", isOn: Binding(
                            get: { settings.pressReturn },
                            set: { settings.pressReturn = $0 }
                        ))
                    }
                }

                if !controller.hotkeyArmed {
                    Button("LIBERAR ACESSIBILIDADE") {
                        Permissions.promptForAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                }
            }
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func preset(_ label: String, _ spec: HotkeySpec) -> some View {
        Button(label) {
            settings.hotkey = spec
            controller.reloadHotkey()
        }
        .buttonStyle(.plain)
        .font(Theme.mono(10, .medium))
        .foregroundStyle(settings.hotkey == spec ? Color.black : Theme.inkDim)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(settings.hotkey == spec ? Theme.accent : Color.white.opacity(0.06))
        .clipShape(Capsule())
    }

    /// A local monitor is enough — the dashboard is key while you're clicking "OUTRA…".
    private func startRecording() {
        recordingKey = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if let spec = HotkeySpec.from(event: event) {
                settings.hotkey = spec
                controller.reloadHotkey()
                stopRecording()
                return nil
            }
            // A flagsChanged we can't map (plain shift, etc.) — keep listening.
            return event.type == .keyDown ? nil : event
        }
    }

    private func stopRecording() {
        recordingKey = false
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                LaunchAtLogin.setEnabled(newValue)
                // Re-read system status — register may land in `.requiresApproval`.
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        )
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { settings.showMenuBar },
            set: { newValue in
                // Never allow both off — the app would become unreachable.
                if !newValue && !settings.showDock { settings.showDock = true }
                settings.showMenuBar = newValue
            }
        )
    }

    private var dockBinding: Binding<Bool> {
        Binding(
            get: { settings.showDock },
            set: { newValue in
                if !newValue && !settings.showMenuBar { settings.showMenuBar = true }
                settings.showDock = newValue
                NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                if !newValue {
                    // Dropping to accessory hides our windows; bring the dashboard back.
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.isVisible || $0.canBecomeKey }?
                        .makeKeyAndOrderFront(nil)
                }
            }
        )
    }
}
