import AppKit
import SwiftUI

@main
struct CochichoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var settings: AppSettings { .shared }
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Cochicho", id: "main") {
            DashboardView(controller: delegate.controller)
                .onAppear { delegate.dashboardOpened() }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra(isInserted: Binding(
            get: { settings.showMenuBar },
            set: { settings.showMenuBar = $0 }
        )) {
            MenuBarContent(controller: delegate.controller, openWindow: openWindow)
        } label: {
            Image(systemName: delegate.controller.state.isActive
                  ? "waveform.circle.fill" : "waveform")
        }
    }
}

struct MenuBarContent: View {
    let controller: DictationController
    let openWindow: OpenWindowAction
    private var settings: AppSettings { .shared }

    var body: some View {
        Button(controller.state.isActive ? "Parar ditado" : "Iniciar ditado") {
            controller.toggleFromUI()
        }
        Divider()
        Picker("Engine", selection: Binding(
            get: { settings.engine },
            set: { settings.engine = $0 }
        )) {
            ForEach(Engine.allCases, id: \.self) { engine in
                Text(engine.displayName).tag(engine)
            }
        }
        Picker("Idioma", selection: Binding(
            get: { settings.language },
            set: { settings.language = $0 }
        )) {
            ForEach(Language.allCases, id: \.self) { language in
                Text(language.displayName).tag(language)
            }
        }
        Divider()
        Button("Abrir Cochicho") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Sair") {
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private var hud: HUDPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(AppSettings.shared.showDock ? .regular : .accessory)

        hud = HUDPanel(controller: controller)
        observeState()

        if !controller.activate() {
            Permissions.promptForAccessibility()
            retryActivation()
        }

        // Warm the Parakeet models when they're the chosen engine and already on disk, so
        // the first dictation isn't a 20-second stall. (Never triggers the 470 MB
        // download implicitly — that's the explicit button in the dashboard.)
        if AppSettings.shared.engine == .parakeet && ParakeetModels.isDownloaded {
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first { $0.identifier?.rawValue.contains("main") ?? false }?
                .makeKeyAndOrderFront(nil)
        }
        return true
    }

    func dashboardOpened() {
        // Re-check permissions whenever the dashboard comes up — the user may have just
        // granted Accessibility in System Settings.
        if !controller.hotkeyArmed {
            controller.reloadHotkey()
        }
    }

    /// There is no notification for an Accessibility grant, so poll until it lands.
    private func retryActivation() {
        Task { @MainActor in
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            controller.activate()
            Log.app.info("Accessibility granted — hotkey armed")
        }
    }

    /// `withObservationTracking` fires once per change, so re-arm after every hit.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.isActive {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.observeState()
            }
        }
    }
}
