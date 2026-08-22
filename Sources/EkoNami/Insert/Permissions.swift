import AppKit
import AVFoundation
import ApplicationServices
import Foundation

enum Permissions {
    @MainActor
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system's "grant Accessibility" dialog if not yet trusted.
    ///
    /// The option key is spelled out rather than using `kAXTrustedCheckOptionPrompt`,
    /// which imports as a mutable global and isn't usable from concurrency-checked code.
    @MainActor
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
