import AppKit
import SwiftUI

@main
struct CochichoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // WindowGroup + external-event routing so AppKit code (the status-item menu) can
        // reopen the dashboard after the user closes it — a plain `Window` scene offers no
        // way back in from outside SwiftUI. `preferring`/`allowing` pin it to one window.
        WindowGroup("Cochicho", id: "main") {
            DashboardView(controller: delegate.controller)
                .onAppear { delegate.dashboardOpened() }
                .handlesExternalEvents(preferring: ["main"], allowing: ["main"])
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["main"])
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// The menu bar icon + menu, in AppKit.
///
/// Not SwiftUI's `MenuBarExtra` on purpose: on macOS 26 it presents its menu detached,
/// floating well below the bar, and exposes no `NSStatusItem` handle to fix the anchor.
/// A classic status item positions natively.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let controller: DictationController
    private var item: NSStatusItem?

    init(controller: DictationController) {
        self.controller = controller
        super.init()
    }

    /// Creates or removes the item per settings, and refreshes the icon. Idempotent —
    /// called from the app-state observation loop on every relevant change.
    func sync() {
        let wanted = AppSettings.shared.showMenuBar
        if wanted && item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            // Rebuilt in `menuNeedsUpdate` each time it opens, so titles and checkmarks
            // are always current without observing every setting individually.
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !wanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let button = item?.button else { return }
        let name = controller.state.isActive ? "waveform.circle.fill" : "waveform"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Cochicho")
        button.image?.isTemplate = true
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem(
            title: controller.state.isActive ? "Parar ditado" : "Iniciar ditado",
            action: #selector(toggleDictation), keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let engineMenu = NSMenu()
        for engine in Engine.allCases {
            let entry = NSMenuItem(
                title: engine.displayName, action: #selector(pickEngine(_:)), keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = engine.rawValue
            entry.state = engine == AppSettings.shared.engine ? .on : .off
            engineMenu.addItem(entry)
        }
        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        let languageMenu = NSMenu()
        for language in Language.allCases {
            let entry = NSMenuItem(
                title: language.displayName.capitalized, action: #selector(pickLanguage(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = language.rawValue
            entry.state = language == AppSettings.shared.language ? .on : .off
            languageMenu.addItem(entry)
        }
        let languageItem = NSMenuItem(title: "Idioma", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        let open = NSMenuItem(
            title: "Abrir Cochicho", action: #selector(openDashboard), keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        let quit = NSMenuItem(title: "Sair", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleDictation() {
        controller.toggleFromUI()
    }

    @objc private func pickEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = Engine(rawValue: raw) else { return }
        AppSettings.shared.engine = engine
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = Language(rawValue: raw) else { return }
        AppSettings.shared.language = language
    }

    @objc private func openDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains("main") ?? false
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Window was closed and released — route back in through the URL scheme,
            // which `handlesExternalEvents` turns into a fresh dashboard window.
            NSWorkspace.shared.open(URL(string: "cochicho://main")!)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private var hud: HUDPanel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(AppSettings.shared.showDock ? .regular : .accessory)

        hud = HUDPanel(controller: controller)
        statusItem = StatusItemController(controller: controller)
        statusItem?.sync()
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
    /// Tracks dictation state (HUD + icon) and the menubar toggle (item lifecycle).
    private func observeState() {
        withObservationTracking {
            _ = controller.state
            _ = AppSettings.shared.showMenuBar
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.isActive {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.statusItem?.sync()
                self.observeState()
            }
        }
    }
}
