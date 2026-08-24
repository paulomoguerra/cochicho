import AppKit
import Carbon.HIToolbox
import Foundation

/// The key that drives dictation. Two families, matched differently at the event tap:
///
/// - **Modifier keys** (Right ⌥, Right ⌘, fn…) arrive as `flagsChanged` and are told apart
///   by device-dependent NX_DEVICE* flag bits, because the public `CGEventFlags` constants
///   are the *union* of left+right and make the release of one side invisible while the
///   other is held.
/// - **Regular keys** (F-keys, letters…) arrive as `keyDown`/`keyUp` and are matched by
///   key code alone.
struct HotkeySpec: Codable, Equatable {
    var keyCode: Int64
    /// NX_DEVICE* mask raw value for modifier keys; 0 for regular keys.
    var modifierFlag: UInt64
    var displayName: String

    var isModifier: Bool { modifierFlag != 0 }

    /// `fn` is shared with system shortcuts (fn+arrows, emoji picker) — swallowing it would
    /// break those, so it's the one key we always pass through.
    var shouldConsumeEvent: Bool { keyCode != Int64(kVK_Function) }

    static let rightOption = HotkeySpec(
        keyCode: Int64(kVK_RightOption), modifierFlag: 0x40, displayName: "R⌥")
    static let rightCommand = HotkeySpec(
        keyCode: Int64(kVK_RightCommand), modifierFlag: 0x10, displayName: "R⌘")
    static let fn = HotkeySpec(
        keyCode: Int64(kVK_Function), modifierFlag: UInt64(CGEventFlags.maskSecondaryFn.rawValue),
        displayName: "FN")

    /// Builds a spec from a key event captured by the recorder UI.
    @MainActor
    static func from(event: NSEvent) -> HotkeySpec? {
        if event.type == .flagsChanged {
            // Only the dedicated modifier keys we can tell apart reliably.
            switch Int64(event.keyCode) {
            case Int64(kVK_RightOption): return .rightOption
            case Int64(kVK_RightCommand): return .rightCommand
            case Int64(kVK_Function): return .fn
            default: return nil
            }
        }
        guard event.type == .keyDown else { return nil }
        let name = Self.name(forKeyCode: event.keyCode)
            ?? event.charactersIgnoringModifiers?.uppercased()
            ?? "KEY \(event.keyCode)"
        return HotkeySpec(keyCode: Int64(event.keyCode), modifierFlag: 0, displayName: name)
    }

    private static func name(forKeyCode code: UInt16) -> String? {
        let names: [UInt16: String] = [
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
            UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
            UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
            UInt16(kVK_Escape): "ESC", UInt16(kVK_Space): "SPACE",
            UInt16(kVK_CapsLock): "CAPS",
        ]
        return names[code]
    }
}
