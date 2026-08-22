import Foundation
import Observation

enum Engine: String, CaseIterable, Codable {
    case apple
    case parakeet
    case whisper

    var displayName: String {
        switch self {
        case .apple: "APPLE LOCAL"
        case .parakeet: "PARAKEET"
        case .whisper: "WHISPER"
        }
    }
}

/// Which Parakeet checkpoint FluidAudio should run.
enum ParakeetVersion: String, CaseIterable, Codable {
    case v3
    case v2

    var displayName: String {
        switch self {
        case .v3: "V3 MULTI"
        case .v2: "V2 EN"
        }
    }
}

enum Language: String, CaseIterable, Codable {
    case ptBR = "pt-BR"
    case enUS = "en-US"

    var locale: Locale { Locale(identifier: rawValue) }

    /// Whisper wants bare ISO 639-1 codes, not BCP-47.
    var whisperCode: String {
        switch self {
        case .ptBR: "pt"
        case .enUS: "en"
        }
    }

    var displayName: String {
        switch self {
        case .ptBR: "PORTUGUÊS"
        case .enUS: "ENGLISH"
        }
    }
}

enum HotkeyMode: String, CaseIterable, Codable {
    case hold
    case toggle

    var displayName: String {
        switch self {
        case .hold: "SEGURAR"
        case .toggle: "ALTERNAR"
        }
    }
}

enum HUDSize: String, CaseIterable, Codable {
    /// Declaration order = picker order: Mínimo → Médio → Grande.
    case minimal
    case medium
    case large

    var displayName: String {
        switch self {
        case .minimal: "MÍNIMO"
        case .medium: "MÉDIO"
        case .large: "GRANDE"
        }
    }

    var panelSize: CGSize {
        switch self {
        case .minimal: CGSize(width: 160, height: 40)
        case .medium: CGSize(width: 380, height: 84)
        // Tall enough for header + waveform + 3 lines of 13pt mono (old 130 clipped the text).
        case .large: CGSize(width: 480, height: 176)
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: "engine") }
    }
    var parakeetVersion: ParakeetVersion {
        didSet { defaults.set(parakeetVersion.rawValue, forKey: "parakeetVersion") }
    }
    /// WhisperKit variant name, e.g. "openai_whisper-base".
    var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: "whisperModel") }
    }
    var language: Language {
        didSet { defaults.set(language.rawValue, forKey: "language") }
    }
    var hotkey: HotkeySpec {
        didSet {
            if let data = try? JSONEncoder().encode(hotkey) {
                defaults.set(data, forKey: "hotkey")
            }
        }
    }
    var hotkeyMode: HotkeyMode {
        didSet { defaults.set(hotkeyMode.rawValue, forKey: "hotkeyMode") }
    }
    var hudSize: HUDSize {
        didSet { defaults.set(hudSize.rawValue, forKey: "hudSize") }
    }
    var showMenuBar: Bool {
        didSet { defaults.set(showMenuBar, forKey: "showMenuBar") }
    }
    var showDock: Bool {
        didSet { defaults.set(showDock, forKey: "showDock") }
    }
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: "soundEnabled") }
    }
    var dictionaryEnabled: Bool {
        didSet { defaults.set(dictionaryEnabled, forKey: "dictionaryEnabled") }
    }
    var saveHistory: Bool {
        didSet { defaults.set(saveHistory, forKey: "saveHistory") }
    }
    var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: "copyToClipboard") }
    }
    var pressReturn: Bool {
        didSet { defaults.set(pressReturn, forKey: "pressReturn") }
    }
    /// Active dashboard tiles: order = pack position, each with its size preset.
    var tileLayout: [TileConfig] {
        didSet {
            Self.persistLayout(tileLayout, key: "tileLayout", to: defaults)
            if tileLayout == TileConfig.defaultLayout {
                layoutSourceIsCustom = false
                // Keep customTileLayout — PADRÃO must not erase the saved custom.
            } else {
                layoutSourceIsCustom = true
                customTileLayout = tileLayout
            }
        }
    }
    /// Last user-customized layout; nil until the user leaves the factory arrangement.
    var customTileLayout: [TileConfig]? {
        didSet {
            if let customTileLayout {
                Self.persistLayout(customTileLayout, key: "customTileLayout", to: defaults)
            }
        }
    }
    /// True when the active layout is the saved custom rather than the factory default.
    var layoutSourceIsCustom: Bool {
        didSet { defaults.set(layoutSourceIsCustom, forKey: "layoutSourceIsCustom") }
    }

    var hasCustomLayout: Bool { customTileLayout != nil }

    func applyDefaultLayout() {
        tileLayout = TileConfig.defaultLayout
    }

    func applyCustomLayout() {
        guard let custom = customTileLayout else { return }
        tileLayout = custom
    }

    private init() {
        engine = Engine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .apple
        parakeetVersion = ParakeetVersion(rawValue: defaults.string(forKey: "parakeetVersion") ?? "") ?? .v3
        whisperModel = defaults.string(forKey: "whisperModel") ?? "openai_whisper-base"
        language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .ptBR
        hotkeyMode = HotkeyMode(rawValue: defaults.string(forKey: "hotkeyMode") ?? "") ?? .hold
        hudSize = Self.loadHUDSize(from: defaults)
        showMenuBar = defaults.object(forKey: "showMenuBar") as? Bool ?? true
        showDock = defaults.object(forKey: "showDock") as? Bool ?? true
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        dictionaryEnabled = defaults.object(forKey: "dictionaryEnabled") as? Bool ?? true
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
        copyToClipboard = defaults.object(forKey: "copyToClipboard") as? Bool ?? false
        pressReturn = defaults.object(forKey: "pressReturn") as? Bool ?? false

        if let data = defaults.data(forKey: "hotkey"),
           let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data) {
            hotkey = spec
        } else {
            hotkey = .rightOption
        }

        let migrated = Self.loadTileLayouts(from: defaults)
        customTileLayout = migrated.custom
        layoutSourceIsCustom = migrated.sourceIsCustom
        tileLayout = migrated.active
        // didSet is skipped during init — persist migration / first-run snapshot explicitly.
        Self.persistLayout(migrated.active, key: "tileLayout", to: defaults)
        if let custom = migrated.custom {
            Self.persistLayout(custom, key: "customTileLayout", to: defaults)
        }
        defaults.set(migrated.sourceIsCustom, forKey: "layoutSourceIsCustom")
    }

    private static func persistLayout(_ layout: [TileConfig], key: String, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: key)
        }
    }

    private static func decodeLayout(key: String, from defaults: UserDefaults) -> [TileConfig]? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([TileConfig].self, from: $0) }
    }

    /// Keep first occurrence of each tile; drop later duplicates.
    private static func dedupe(_ layout: [TileConfig]) -> [TileConfig] {
        var seen = Set<Tile>()
        return layout.filter { seen.insert($0.tile).inserted }
    }

    private static func appendingMissingTiles(_ layout: [TileConfig]) -> [TileConfig] {
        var result = layout
        for tile in Tile.allCases where !result.contains(where: { $0.tile == tile }) {
            result.append(TileConfig(tile: tile, size: .small))
        }
        return result
    }

    private static func loadTileLayouts(from defaults: UserDefaults) -> (
        active: [TileConfig], custom: [TileConfig]?, sourceIsCustom: Bool
    ) {
        var custom = decodeLayout(key: "customTileLayout", from: defaults).map(dedupe)
        let saved = decodeLayout(key: "tileLayout", from: defaults).map(dedupe)
        let hasSourceKey = defaults.object(forKey: "layoutSourceIsCustom") != nil

        var active: [TileConfig]
        var sourceIsCustom: Bool

        if hasSourceKey {
            sourceIsCustom = defaults.bool(forKey: "layoutSourceIsCustom")
            if sourceIsCustom {
                if let saved {
                    active = saved
                } else if let custom {
                    active = custom
                } else {
                    active = TileConfig.defaultLayout
                    sourceIsCustom = false
                }
                if custom == nil { custom = saved }
            } else {
                // Factory users always pick up the current default — ignore stale snapshots.
                active = TileConfig.defaultLayout
                sourceIsCustom = false
            }
        } else if let saved {
            if saved == TileConfig.legacyDefaultLayout
                || saved == TileConfig.previousDefaultLayout
                || saved == TileConfig.defaultLayout
            {
                active = TileConfig.defaultLayout
                sourceIsCustom = false
            } else {
                active = saved
                sourceIsCustom = true
                if custom == nil { custom = saved }
            }
        } else {
            active = TileConfig.defaultLayout
            sourceIsCustom = false
        }

        active = appendingMissingTiles(active)
        if let existing = custom {
            custom = appendingMissingTiles(existing)
        }
        return (active, custom, sourceIsCustom)
    }

    /// One-shot map from the old PADRÃO/MÉDIO/MÍNIMO raw values onto the renamed cases.
    /// `medium` used to mean "grande"; after migration it means the former padrão — so
    /// we must not keep remapping it on every launch.
    private static func loadHUDSize(from defaults: UserDefaults) -> HUDSize {
        let key = "hudSize"
        let flag = "hudSizeRenamedToMinMedLarge"
        let raw = defaults.string(forKey: key) ?? ""
        if defaults.bool(forKey: flag) {
            return HUDSize(rawValue: raw) ?? .medium
        }
        defaults.set(true, forKey: flag)
        let size: HUDSize = switch raw {
        case "standard": .medium
        case "medium": .large
        case "minimal": .minimal
        case "large": .large
        default: .medium
        }
        defaults.set(size.rawValue, forKey: key)
        return size
    }
}
