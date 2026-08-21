import Foundation
import Observation

enum Engine: String, CaseIterable, Codable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple: "APPLE LOCAL"
        case .parakeet: "PARAKEET V3"
        }
    }
}

enum Language: String, CaseIterable, Codable {
    case ptBR = "pt-BR"
    case enUS = "en-US"

    var locale: Locale { Locale(identifier: rawValue) }

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

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: "engine") }
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
    var showMenuBar: Bool {
        didSet { defaults.set(showMenuBar, forKey: "showMenuBar") }
    }
    var showDock: Bool {
        didSet { defaults.set(showDock, forKey: "showDock") }
    }
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: "soundEnabled") }
    }

    private init() {
        engine = Engine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .apple
        language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .ptBR
        hotkeyMode = HotkeyMode(rawValue: defaults.string(forKey: "hotkeyMode") ?? "") ?? .hold
        showMenuBar = defaults.object(forKey: "showMenuBar") as? Bool ?? true
        showDock = defaults.object(forKey: "showDock") as? Bool ?? true
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true

        if let data = defaults.data(forKey: "hotkey"),
           let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data) {
            hotkey = spec
        } else {
            hotkey = .rightOption
        }
    }
}
