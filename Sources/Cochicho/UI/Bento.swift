import SwiftUI

/// The dashboard's six tiles, identified stably for layout persistence.
enum Tile: String, Codable, CaseIterable, Identifiable {
    case mic, engine, stats, history, dictionary, controls

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mic: "MIC"
        case .engine: "ENGINE"
        case .stats: "STATS"
        case .history: "HISTÓRICO"
        case .dictionary: "DICIONÁRIO"
        case .controls: "CONTROLES"
        }
    }
}

/// The four tile footprints on the 4-column grid. Content adapts to the preset — not to
/// measured pixels — so what shows at each size is deterministic.
enum TileSize: String, Codable, CaseIterable {
    case small   // 1×1
    case wide    // 2×1
    case tall    // 1×2
    case big     // 2×2

    var columns: Int {
        switch self {
        case .small, .tall: 1
        case .wide, .big: 2
        }
    }

    var rows: Int {
        switch self {
        case .small, .wide: 1
        case .tall, .big: 2
        }
    }

    /// Single-letter label for the edit-mode size picker.
    var label: String {
        switch self {
        case .small: "P"
        case .wide: "L"
        case .tall: "A"
        case .big: "G"
        }
    }

    /// Room for secondary controls (extra stats, add-forms, flags)?
    var isRoomy: Bool { self == .tall || self == .big }
}

/// One tile's slot in the saved layout.
struct TileConfig: Codable, Equatable, Identifiable {
    var tile: Tile
    var size: TileSize

    var id: String { tile.rawValue }

    /// Mirrors the fixed pre-customization dashboard.
    static let defaultLayout: [TileConfig] = [
        TileConfig(tile: .mic, size: .wide),
        TileConfig(tile: .engine, size: .tall),
        TileConfig(tile: .stats, size: .small),
        TileConfig(tile: .history, size: .big),
        TileConfig(tile: .dictionary, size: .tall),
        TileConfig(tile: .controls, size: .tall),
    ]
}

/// Span a subview declares to `BentoLayout`.
private struct TileSpanKey: LayoutValueKey {
    static let defaultValue = TileSize.small
}

extension View {
    func tileSpan(_ size: TileSize) -> some View {
        layoutValue(key: TileSpanKey.self, value: size)
    }
}

/// Packs tiles into a fixed-column grid, first-fit top-left. Order of subviews is the
/// order the user arranged; a tile whose span doesn't fit the current row slides down to
/// the first free slot, so there are no holes the user has to manage by hand.
struct BentoLayout: Layout {
    var columns = 4
    var spacing: CGFloat = 14
    var rowHeight: CGFloat = 234

    struct Cache {
        var frames: [CGRect] = []
        var totalRows = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func computePlacement(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        let cellWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var occupied: [[Bool]] = []
        cache.frames = []
        cache.totalRows = 0

        func ensureRows(_ count: Int) {
            while occupied.count < count {
                occupied.append(Array(repeating: false, count: columns))
            }
        }

        func fits(row: Int, col: Int, size: TileSize) -> Bool {
            guard col + size.columns <= columns else { return false }
            ensureRows(row + size.rows)
            for r in row..<(row + size.rows) {
                for c in col..<(col + size.columns) where occupied[r][c] {
                    return false
                }
            }
            return true
        }

        for subview in subviews {
            let size = subview[TileSpanKey.self]
            var placedAt: (row: Int, col: Int)? = nil
            var row = 0
            while placedAt == nil {
                ensureRows(row + 1)
                for col in 0..<columns where fits(row: row, col: col, size: size) {
                    placedAt = (row, col)
                    break
                }
                row += 1
            }

            let (r, c) = placedAt!
            for rr in r..<(r + size.rows) {
                for cc in c..<(c + size.columns) {
                    occupied[rr][cc] = true
                }
            }
            cache.totalRows = max(cache.totalRows, r + size.rows)

            cache.frames.append(CGRect(
                x: CGFloat(c) * (cellWidth + spacing),
                y: CGFloat(r) * (rowHeight + spacing),
                width: cellWidth * CGFloat(size.columns) + spacing * CGFloat(size.columns - 1),
                height: rowHeight * CGFloat(size.rows) + spacing * CGFloat(size.rows - 1)
            ))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 980
        computePlacement(width: width, subviews: subviews, cache: &cache)
        let height = CGFloat(cache.totalRows) * rowHeight
            + CGFloat(max(0, cache.totalRows - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        computePlacement(width: bounds.width, subviews: subviews, cache: &cache)
        for (subview, frame) in zip(subviews, cache.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}
