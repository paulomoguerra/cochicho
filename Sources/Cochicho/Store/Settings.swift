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
    /// User-arranged dashboard tiles: order = position, each with its size preset.
    var tileLayout: [TileConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(tileLayout) {
                defaults.set(data, forKey: "tileLayout")
            }
        }
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

        if let data = defaults.data(forKey: "hotkey"),
           let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data) {
            hotkey = spec
        } else {
            hotkey = .rightOption
        }

        // Any tile missing from the saved layout (say, added in an update) is appended
        // small at the end rather than vanishing.
        var layout = (defaults.data(forKey: "tileLayout"))
            .flatMap { try? JSONDecoder().decode([TileConfig].self, from: $0) }
            ?? TileConfig.defaultLayout
        for tile in Tile.allCases where !layout.contains(where: { $0.tile == tile }) {
            layout.append(TileConfig(tile: tile, size: .small))
        }
        tileLayout = layout
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
