import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` — the modern Login Items API (macOS 13+).
///
/// Source of truth is the system status, not UserDefaults: the user can also flip this
/// in Ajustes ▸ Geral ▸ Itens de Início e Extensões.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the main app as a login item.
    /// Opens System Settings when the OS asks for explicit approval.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            return service.status == .enabled || (!enabled && service.status == .notRegistered)
        } catch {
            // Already in the desired state — treat as success.
            let code = (error as NSError).code
            if enabled, service.status == .enabled { return true }
            if !enabled, service.status == .notRegistered { return true }
            Log.app.error("launch at login: \(error.localizedDescription) (\(code))")
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
            return service.status == .enabled
        }
    }
}
