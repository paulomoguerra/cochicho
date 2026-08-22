import SwiftUI

/// Design tokens — dark bento dashboard, dot-matrix instruments, one hot accent.
enum Theme {
    static let bg = Color(red: 0.075, green: 0.07, blue: 0.065)
    static let card = Color(red: 0.115, green: 0.11, blue: 0.105)
    static let cardBorder = Color.white.opacity(0.06)
    static let ink = Color(red: 0.93, green: 0.91, blue: 0.88)
    static let inkDim = Color.white.opacity(0.42)
    static let inkFaint = Color.white.opacity(0.22)
    static let accent = Color(red: 1.0, green: 0.27, blue: 0.0)
    static let ok = Color(red: 0.35, green: 0.85, blue: 0.55)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The numbered card chrome from the reference: "01 MIC" in tracked mono caps.
struct CardHeader: View {
    let number: String
    let title: String
    var trailing: String? = nil
    var trailingColor: Color = Theme.inkDim

    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.inkFaint)
            Text(title)
                .font(Theme.mono(10, .medium))
                .tracking(2)
                .foregroundStyle(Theme.inkDim)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Theme.mono(10, .medium))
                    .tracking(1)
                    .foregroundStyle(trailingColor)
            }
        }
        .textCase(.uppercase)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.cardBorder, lineWidth: 1)
            )
    }
}

/// Small stat block: label on top, big mono value below.
struct Stat: View {
    let label: String
    let value: String
    var color: Color = Theme.ink
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 4) {
            Text(label)
                .font(Theme.mono(compact ? 8 : 9))
                .tracking(1.5)
                .foregroundStyle(Theme.inkFaint)
                .textCase(.uppercase)
            Text(value)
                .font(Theme.mono(compact ? 13 : 20, .medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

/// Dot-matrix waveform — columns of dots lit from the middle out by the mic level.
struct DotWaveform: View {
    /// Recent levels, newest last. 0…1 each.
    let levels: [Float]
    var columns = 36
    var rows = 7
    var idle = false

    var body: some View {
        Canvas { context, size in
            let dotGapX = size.width / CGFloat(columns)
            let dotGapY = size.height / CGFloat(rows)
            let radius: CGFloat = min(dotGapX, dotGapY) * 0.28

            for col in 0..<columns {
                let index = levels.count - columns + col
                let level = index >= 0 && index < levels.count ? CGFloat(levels[index]) : 0
                let lit = idle ? 0 : Int((level * CGFloat(rows)).rounded())
                let mid = rows / 2

                for row in 0..<rows {
                    let distance = abs(row - mid)
                    let isLit = distance <= lit / 2 && lit > 0
                    let center = CGPoint(
                        x: dotGapX * (CGFloat(col) + 0.5),
                        y: dotGapY * (CGFloat(row) + 0.5)
                    )
                    let rect = CGRect(
                        x: center.x - radius, y: center.y - radius,
                        width: radius * 2, height: radius * 2
                    )
                    let color: Color =
                        if isLit && level > 0.6 { Theme.accent }
                        else if isLit { Theme.ink.opacity(0.85) }
                        else { Color.white.opacity(row == mid ? 0.14 : 0.07) }
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
    }
}

/// Dotted ring with a number in the middle — the "device overview" instrument.
struct DottedRing: View {
    let value: String
    let caption: String
    /// 0…1 share of the ring drawn in the accent color.
    var progress: Double = 1

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let ringRadius = min(size.width, size.height) / 2 - 6
                let dots = 48
                for i in 0..<dots {
                    let angle = Double(i) / Double(dots) * 2 * .pi - .pi / 2
                    let point = CGPoint(
                        x: center.x + cos(angle) * ringRadius,
                        y: center.y + sin(angle) * ringRadius
                    )
                    let active = Double(i) / Double(dots) < progress
                    let rect = CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(active ? Theme.ink.opacity(0.8) : Color.white.opacity(0.12))
                    )
                }
            }
            VStack(spacing: 2) {
                Text(value)
                    .font(Theme.mono(26, .medium))
                    .foregroundStyle(Theme.ink)
                Text(caption)
                    .font(Theme.mono(9))
                    .tracking(1.5)
                    .foregroundStyle(Theme.inkFaint)
                    .textCase(.uppercase)
            }
        }
    }
}

/// Thin accent-filled progress bar; `fraction == nil` renders an indeterminate sweep.
struct DownloadBar: View {
    var fraction: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if let fraction {
                    Capsule().fill(Theme.accent)
                        .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                } else {
                    Capsule().fill(Theme.accent)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: sweep ? geo.size.width * 0.7 : 0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: sweep)
                        .onAppear { sweep = true }
                }
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
    }
}

/// Pill button in the house style.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(11, .medium))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(prominent ? Color.black : Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(prominent ? Theme.accent : Color.white.opacity(0.07))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Segmented picker rendered as flat mono pills.
struct SegmentPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(Theme.mono(10, .medium))
                        .tracking(1)
                        .foregroundStyle(selection == value ? Color.black : Theme.inkDim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selection == value ? Theme.accent : Color.white.opacity(0.06))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Flat mono toggle row.
struct FlagRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack {
                Text(label)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(isOn ? "ON" : "OFF")
                    .font(Theme.mono(10, .semibold))
                    .tracking(1)
                    .foregroundStyle(isOn ? Theme.ok : Theme.inkFaint)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
    }
}
