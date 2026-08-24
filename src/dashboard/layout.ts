import type { TileConfig, TileId, TileSize } from "../lib/ipc";

export type { TileSize, TileId, TileConfig };

export const COLUMNS = 4;
export const ROW_HEIGHT = 234;
export const GRID_GAP = 14;

export const DEFAULT_LAYOUT: TileConfig[] = [
  { tile: "mic", size: "wide" },
  { tile: "engine", size: "tall" },
  { tile: "stats", size: "small" },
  { tile: "history", size: "big" },
  { tile: "controls", size: "tall" },
  { tile: "dictionary", size: "small" },
];

export const TILE_TITLE: Record<TileId, string> = {
  mic: "MIC",
  engine: "ENGINE",
  stats: "STATS",
  history: "HISTÓRICO",
  dictionary: "DICIONÁRIO",
  controls: "CONTROLES",
};

export const TILE_NUMBER: Record<TileId, string> = {
  mic: "01",
  engine: "02",
  stats: "03",
  history: "04",
  dictionary: "05",
  controls: "06",
};

export const SIZE_LABEL: Record<TileSize, string> = {
  small: "P",
  wide: "L",
  tall: "A",
  big: "G",
};

export const ALL_SIZES: TileSize[] = ["small", "wide", "tall", "big"];

export function sizeCols(size: TileSize): number {
  return size === "wide" || size === "big" ? 2 : 1;
}

export function sizeRows(size: TileSize): number {
  return size === "tall" || size === "big" ? 2 : 1;
}

export function isRoomy(size: TileSize): boolean {
  return size === "tall" || size === "big";
}

export function layoutsEqual(a: TileConfig[], b: TileConfig[]): boolean {
  if (a.length !== b.length) return false;
  return a.every((c, i) => c.tile === b[i]?.tile && c.size === b[i]?.size);
}

export interface PlacedTile {
  config: TileConfig;
  col: number;
  row: number;
  colSpan: number;
  rowSpan: number;
}

/** First-fit top-left — port de `BentoLayout.computePlacement`. */
export function packTiles(configs: TileConfig[]): { placed: PlacedTile[]; totalRows: number } {
  const occupied: boolean[][] = [];
  const placed: PlacedTile[] = [];
  let totalRows = 0;

  const ensureRows = (count: number) => {
    while (occupied.length < count) {
      occupied.push(Array.from({ length: COLUMNS }, () => false));
    }
  };

  const fits = (row: number, col: number, cols: number, rows: number): boolean => {
    if (col + cols > COLUMNS) return false;
    ensureRows(row + rows);
    for (let r = row; r < row + rows; r++) {
      for (let c = col; c < col + cols; c++) {
        if (occupied[r]?.[c]) return false;
      }
    }
    return true;
  };

  for (const config of configs) {
    const cols = sizeCols(config.size);
    const rows = sizeRows(config.size);
    let placedAt: { row: number; col: number } | null = null;
    let row = 0;
    while (!placedAt) {
      ensureRows(row + 1);
      for (let col = 0; col < COLUMNS; col++) {
        if (fits(row, col, cols, rows)) {
          placedAt = { row, col };
          break;
        }
      }
      row += 1;
    }

    const { row: r, col: c } = placedAt;
    for (let rr = r; rr < r + rows; rr++) {
      for (let cc = c; cc < c + cols; cc++) {
        const line = occupied[rr];
        if (line) line[cc] = true;
      }
    }
    totalRows = Math.max(totalRows, r + rows);
    placed.push({ config, col: c, row: r, colSpan: cols, rowSpan: rows });
  }

  return { placed, totalRows };
}

export function moveTile(layout: TileConfig[], from: TileId, to: TileId): TileConfig[] {
  const next = [...layout];
  const fromIdx = next.findIndex((c) => c.tile === from);
  if (fromIdx < 0) return layout;
  const [item] = next.splice(fromIdx, 1);
  if (!item) return layout;
  // Após remover, o alvo ainda está na lista — inserir antes dele (slot do hover).
  const toIdx = next.findIndex((c) => c.tile === to);
  if (toIdx < 0) {
    next.push(item);
    return next;
  }
  next.splice(toIdx, 0, item);
  return next;
}

export function moveTileToEnd(layout: TileConfig[], tile: TileId): TileConfig[] {
  const next = [...layout];
  const idx = next.findIndex((c) => c.tile === tile);
  if (idx < 0) return layout;
  const [item] = next.splice(idx, 1);
  if (!item) return layout;
  next.push(item);
  return next;
}

export function setTileSize(layout: TileConfig[], tile: TileId, size: TileSize): TileConfig[] {
  return layout.map((c) => (c.tile === tile ? { ...c, size } : c));
}

export function activeLayout(settings: {
  tile_layout: TileConfig[];
  custom_tile_layout: TileConfig[];
  layout_source_is_custom: boolean;
}): TileConfig[] {
  if (settings.layout_source_is_custom && settings.custom_tile_layout.length > 0) {
    return settings.custom_tile_layout;
  }
  return settings.tile_layout.length > 0 ? settings.tile_layout : DEFAULT_LAYOUT;
}
