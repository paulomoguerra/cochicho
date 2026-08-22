import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The "Buy me a coffee" window: a Lightning QR in the app's visual language.
///
/// The QR keeps dark modules on a light card — inverted codes fail in many scanner apps —
/// but the light is the theme's ink cream, not pure white, so the card still reads as ours.
struct CoffeeView: View {
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("BUY ME A COFFEE")
                    .font(Theme.mono(10, .medium)).tracking(2)
                    .foregroundStyle(Theme.inkDim)
                Spacer()
                Text("EKO NAMI")
                    .font(Theme.mono(8, .medium)).tracking(2)
                    .foregroundStyle(Theme.inkFaint)
            }

            if let qr = Self.qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 216, height: 216)
                    .padding(12)
                    .background(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Donation.lnurl, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Text(copied ? "COPIADO ✓" : Donation.abbreviated)
                    .font(Theme.mono(9)).tracking(1)
                    .foregroundStyle(copied ? Theme.ok : Theme.inkFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 280)
        .background(Theme.bg)
    }

    /// Uppercased bech32 keeps the QR in alphanumeric mode — fewer modules, easier scan.
    private static let qrImage: NSImage? = {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("lightning:\(Donation.lnurl)".uppercased().utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }()
}

/// One retained window, recentered and re-keyed on every menu click.
@MainActor
final class CoffeePanel {
    static let shared = CoffeePanel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: CoffeeView())
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(Theme.bg)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
