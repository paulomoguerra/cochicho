import Foundation

/// One-shot migration from the app's previous identity (Cochicho, com.mateus.cochicho).
///
/// Must run before any store or setting is touched: it moves the Application Support
/// folder (history, dictionary, Whisper models) and imports the old UserDefaults domain
/// (engine, hotkey, layouts, toggles) into the new one. TCC grants don't migrate — the
/// new bundle id re-prompts for Accessibility and microphone, and the existing
/// permission flow handles that.
enum LegacyMigration {
    static func run() {
        migrateAppSupport()
        migrateDefaults()
    }

    /// Application Support/Cochicho → EkoNami, only while the new folder doesn't exist.
    private static func migrateAppSupport() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("Cochicho", isDirectory: true)
        let new = support.appendingPathComponent("EkoNami", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
            Log.app.info("migrated Application Support/Cochicho → EkoNami")
        } catch {
            Log.app.error("App Support migration failed: \(error.localizedDescription)")
        }
    }

    /// Copies every key from the old defaults domain, once. The old plist is read straight
    /// from disk — the old app no longer runs, so cfprefsd staleness isn't a concern.
    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        let flag = "migratedFromCochicho"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.mateus.cochicho.plist")
        guard let values = NSDictionary(contentsOf: plist) as? [String: Any], !values.isEmpty
        else { return }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        Log.app.info("imported \(values.count) settings from com.mateus.cochicho")
    }
}
