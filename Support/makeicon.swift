#!/usr/bin/env swift
// Renders the Cochicho app icon: a dot-matrix waveform "whisper" on the house dark card,
// one hot orange column. Run via `make icon`.
import AppKit

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

func draw(size: Int) -> NSImage {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    let inset = side * 0.05
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: side * 0.21, yRadius: side * 0.21)
    NSColor(calibratedRed: 0.115, green: 0.11, blue: 0.105, alpha: 1).setFill()
    bg.fill()

    // Dot-matrix waveform: symmetric columns, heights hand-picked to read as speech.
    let heights: [CGFloat] = [2, 4, 3, 6, 9, 5, 7, 3, 5, 2]
    let accentColumn = 4
    let columns = heights.count
    let rows = 9
    let gridW = rect.width * 0.72
    let gridH = rect.height * 0.62
    let originX = rect.midX - gridW / 2
    let originY = rect.midY - gridH / 2
    let stepX = gridW / CGFloat(columns - 1)
    let stepY = gridH / CGFloat(rows - 1)
    let dotR = side * 0.028

    for col in 0..<columns {
        let lit = Int(heights[col])
        let mid = rows / 2
        for row in 0..<rows {
            let isLit = abs(row - mid) <= lit / 2
            let color: NSColor = if isLit && col == accentColumn {
                NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.0, alpha: 1)
            } else if isLit {
                NSColor(calibratedWhite: 0.92, alpha: 0.92)
            } else {
                NSColor(calibratedWhite: 1, alpha: 0.09)
            }
            color.setFill()
            let center = NSPoint(
                x: originX + CGFloat(col) * stepX,
                y: originY + CGFloat(row) * stepY
            )
            NSBezierPath(ovalIn: NSRect(
                x: center.x - dotR, y: center.y - dotR,
                width: dotR * 2, height: dotR * 2
            )).fill()
        }
    }

    image.unlockFocus()
    return image
}

let iconsetURL = URL(fileURLWithPath: "Support/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = draw(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: iconsetURL.appendingPathComponent("\(name).png"))
}
print("iconset written")
