import AppKit
import Foundation

/// Watches the dictation hotkey with a `CGEventTap`.
///
/// A tap rather than `NSEvent.addGlobalMonitor` because `fn` and left/right modifier
/// discrimination don't surface through the higher-level APIs, and because consuming the
/// event (so an F-key hotkey doesn't also type into the target app) is tap-only.
/// Needs Accessibility permission; without it `CGEvent.tapCreate` returns nil.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    var spec: HotkeySpec = .rightOption
    var mode: HotkeyMode = .hold
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Toggle mode fires this instead of press/release pairs.
    var onToggle: (() -> Void)?

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility.
    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // CGEvent isn't Sendable — pull plain values out before crossing into
                // actor-isolated code. The tap runs on the main run loop.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let flags = event.flags
                let consume = MainActor.assumeIsolated {
                    monitor.handle(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for \(self.spec.displayName) (\(self.mode.rawValue))")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isPressed = false
    }

    // MARK: - Tap callback

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    private func handle(type: CGEventType, keyCode: Int64, isRepeat: Bool, flags: CGEventFlags) -> Bool {
        // The system disables a tap that runs too slowly or is interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        if spec.isModifier {
            guard type == .flagsChanged, keyCode == spec.keyCode else { return false }
            let nowPressed = flags.contains(CGEventFlags(rawValue: spec.modifierFlag))
            guard nowPressed != isPressed else { return false }
            isPressed = nowPressed
            fire(pressed: nowPressed)
            return spec.shouldConsumeEvent
        }

        guard keyCode == spec.keyCode, type == .keyDown || type == .keyUp else { return false }
        guard !isRepeat else { return spec.shouldConsumeEvent }

        let nowPressed = type == .keyDown
        guard nowPressed != isPressed else { return spec.shouldConsumeEvent }
        isPressed = nowPressed
        fire(pressed: nowPressed)
        return spec.shouldConsumeEvent
    }

    private func fire(pressed: Bool) {
        switch mode {
        case .hold:
            pressed ? onPress?() : onRelease?()
        case .toggle:
            if pressed { onToggle?() }
        }
    }
}
