import { useCallback, useEffect, useMemo, useState } from "react";
import {
  type Appearance,
  type DictationState,
  type DictionaryEntry,
  type HistoryEntry,
  type HistoryTotals,
  type Settings,
  type TileConfig,
  type TileId,
  dictationState,
  dictionaryList,
  historyList,
  historyTotals,
  onDictationState,
  onDictionaryChanged,
  onHistoryChanged,
  onHotkeyUnavailable,
  onSettingsChanged,
  onTranscript,
  platformInfo,
  settingsGet,
  settingsUpdate,
} from "../lib/ipc";
import {
  ALL_SIZES,
  DEFAULT_LAYOUT,
  GRID_GAP,
  ROW_HEIGHT,
  SIZE_LABEL,
  activeLayout,
  layoutsEqual,
  moveTile,
  moveTileToEnd,
  packTiles,
  setTileSize,
  type TileSize,
} from "./layout";
import { ControlsTile } from "./tiles/ControlsTile";
import { DictionaryTile } from "./tiles/DictionaryTile";
import { EngineTile } from "./tiles/EngineTile";
import { HistoryTile } from "./tiles/HistoryTile";
import { MicTile } from "./tiles/MicTile";
import { StatsTile } from "./tiles/StatsTile";
import { PillButton, SegmentPicker } from "./ui";
import { applyAppearance } from "../lib/theme";

const EMPTY_TOTALS: HistoryTotals = { total_words: 0, total_seconds: 0, entry_count: 0 };

export default function Dashboard() {
  const [settings, setSettings] = useState<Settings | null>(null);
  const [state, setState] = useState<DictationState>("idle");
  const [error, setError] = useState<string | null>(null);
  const [transcript, setTranscript] = useState("");
  const [platform, setPlatform] = useState("");
  const [hotkeyWarning, setHotkeyWarning] = useState<string | null>(null);
  const [entries, setEntries] = useState<DictionaryEntry[]>([]);
  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [totals, setTotals] = useState<HistoryTotals>(EMPTY_TOTALS);
  const [editingLayout, setEditingLayout] = useState(false);
  const [dragged, setDragged] = useState<TileId | null>(null);
  const [didReorder, setDidReorder] = useState(false);

  const isMac = platform.startsWith("macos");
  const isLinux = platform.startsWith("linux");

  const refreshDictionary = useCallback(() => {
    dictionaryList()
      .then(setEntries)
      .catch(() => {});
  }, []);

  const refreshHistory = useCallback(() => {
    historyList()
      .then(setHistory)
      .catch(() => {});
    historyTotals()
      .then(setTotals)
      .catch(() => {});
  }, []);

  useEffect(() => {
    settingsGet()
      .then(setSettings)
      .catch(() => {});
    dictationState()
      .then((p) => setState(p.state))
      .catch(() => {});
    platformInfo()
      .then(setPlatform)
      .catch(() => {});
    refreshDictionary();
    refreshHistory();

    const unlisteners = [
      onDictationState((p) => {
        setState(p.state);
        setError(p.error);
      }),
      onTranscript((p) => setTranscript(p.text)),
      onHotkeyUnavailable(setHotkeyWarning),
      onSettingsChanged(setSettings),
      onDictionaryChanged(refreshDictionary),
      onHistoryChanged(refreshHistory),
    ];
    return () => {
      unlisteners.forEach((u) => u.then((fn) => fn()));
    };
  }, [refreshDictionary, refreshHistory]);

  const layout = useMemo(
    () => (settings ? activeLayout(settings) : DEFAULT_LAYOUT),
    [settings],
  );
  const { placed, totalRows } = useMemo(() => packTiles(layout), [layout]);
  const hasCustom = (settings?.custom_tile_layout.length ?? 0) > 0;

  const persistLayout = (next: TileConfig[]) => {
    if (layoutsEqual(next, DEFAULT_LAYOUT)) {
      void settingsUpdate({
        tile_layout: next,
        layout_source_is_custom: false,
      });
    } else {
      void settingsUpdate({
        tile_layout: next,
        custom_tile_layout: next,
        layout_source_is_custom: true,
      });
    }
  };

  const status = (() => {
    if (state === "failed" && error) return { line: error.toUpperCase(), cls: "err" as const };
    if (hotkeyWarning) return { line: "HOTKEY INDISPONÍVEL", cls: "warn" as const };
    if (state === "listening") return { line: "OUVINDO", cls: "rec" as const };
    if (state === "starting") return { line: "PREPARANDO", cls: "rec" as const };
    if (state === "finishing") return { line: "TRANSCREVENDO", cls: "rec" as const };
    const hotkey = settings?.hotkey.display_name ?? "—";
    const engine = settings?.engine?.toUpperCase() ?? (isMac ? "APPLE" : "—");
    return { line: `PRONTO · ${hotkey} · ${engine}`, cls: "" as const };
  })();

  if (!settings) {
    return <div className="dash muted">…</div>;
  }

  return (
    <div className="dash">
      <header className="dash-header">
        <div>
          <div className="dash-brand">E K O   N A M I</div>
          <div className="dash-tagline">VOICE → TEXT · 100% LOCAL</div>
        </div>
        <div className="dash-header-right">
          <SegmentPicker<Appearance>
            options={[
              { value: "dark", label: "ESCURO" },
              { value: "light", label: "CLARO" },
            ]}
            value={settings.appearance ?? "dark"}
            onChange={(appearance) => {
              applyAppearance(appearance);
              void settingsUpdate({ appearance });
            }}
          />
          <div className="dash-status">
            <span className={`dash-status-dot ${status.cls}`} />
            {status.line}
          </div>
          {editingLayout && (
            <>
              <PillButton
                prominent={!settings.layout_source_is_custom}
                onClick={() => {
                  void settingsUpdate({
                    tile_layout: DEFAULT_LAYOUT,
                    layout_source_is_custom: false,
                  });
                }}
              >
                PADRÃO
              </PillButton>
              {hasCustom && (
                <PillButton
                  prominent={settings.layout_source_is_custom}
                  onClick={() => {
                    void settingsUpdate({
                      tile_layout: settings.custom_tile_layout,
                      layout_source_is_custom: true,
                    });
                  }}
                >
                  MEU
                </PillButton>
              )}
            </>
          )}
          <PillButton
            prominent={editingLayout}
            onClick={() => {
              setEditingLayout((v) => !v);
              setDragged(null);
              setDidReorder(false);
            }}
          >
            {editingLayout ? "PRONTO" : "LAYOUT"}
          </PillButton>
        </div>
      </header>

      <div
        className="bento"
        style={{
          gridTemplateRows: `repeat(${Math.max(totalRows, 1)}, ${ROW_HEIGHT}px)`,
          minHeight: totalRows * ROW_HEIGHT + Math.max(0, totalRows - 1) * GRID_GAP,
        }}
        onDragOver={(e) => {
          if (editingLayout) e.preventDefault();
        }}
        onDrop={(e) => {
          if (!editingLayout || !dragged) return;
          e.preventDefault();
          if (!didReorder) persistLayout(moveTileToEnd(layout, dragged));
          setDragged(null);
          setDidReorder(false);
        }}
      >
        {placed.map(({ config, col, row, colSpan, rowSpan }) => (
          <div
            key={config.tile}
            className={`tile-shell${editingLayout ? " edit" : ""}${dragged === config.tile ? " dragging" : ""}`}
            style={{
              gridColumn: `${col + 1} / span ${colSpan}`,
              gridRow: `${row + 1} / span ${rowSpan}`,
            }}
            onDragOver={(e) => {
              if (!editingLayout || !dragged || dragged === config.tile) return;
              e.preventDefault();
              e.stopPropagation();
              const next = moveTile(layout, dragged, config.tile);
              if (layoutsEqual(next, layout)) return;
              setDidReorder(true);
              persistLayout(next);
            }}
            onDrop={(e) => {
              if (!editingLayout) return;
              e.preventDefault();
              e.stopPropagation();
              setDragged(null);
              setDidReorder(false);
            }}
          >
            {renderTile(config.tile, config.size, {
              settings,
              state,
              error,
              transcript,
              hotkeyWarning,
              entries,
              history,
              totals,
              isMac,
              isLinux,
            })}
            {editingLayout && (
              <>
                <div
                  className="tile-drag-overlay"
                  draggable
                  onDragStart={() => {
                    setDragged(config.tile);
                    setDidReorder(false);
                  }}
                  onDragEnd={() => {
                    setDragged(null);
                    setDidReorder(false);
                  }}
                />
                <div className="size-picker">
                  {ALL_SIZES.map((s) => (
                    <button
                      key={s}
                      type="button"
                      className={`size-dot${config.size === s ? " on" : ""}`}
                      onClick={() => persistLayout(setTileSize(layout, config.tile, s))}
                    >
                      {SIZE_LABEL[s]}
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

function renderTile(
  tile: TileId,
  size: TileSize,
  ctx: {
    settings: Settings;
    state: DictationState;
    error: string | null;
    transcript: string;
    hotkeyWarning: string | null;
    entries: DictionaryEntry[];
    history: HistoryEntry[];
    totals: HistoryTotals;
    isMac: boolean;
    isLinux: boolean;
  },
) {
  switch (tile) {
    case "mic":
      return (
        <MicTile
          size={size}
          state={ctx.state}
          error={ctx.error}
          transcript={ctx.transcript}
          hotkeyName={ctx.settings.hotkey.display_name}
          hotkeyWarning={ctx.hotkeyWarning}
        />
      );
    case "engine":
      return <EngineTile size={size} settings={ctx.settings} isMac={ctx.isMac} />;
    case "stats":
      return <StatsTile size={size} entries={ctx.history} totals={ctx.totals} />;
    case "history":
      return (
        <HistoryTile
          size={size}
          entries={ctx.history}
          saveHistory={ctx.settings.save_history}
        />
      );
    case "dictionary":
      return (
        <DictionaryTile
          entries={ctx.entries}
          dictionaryEnabled={ctx.settings.dictionary_enabled}
        />
      );
    case "controls":
      return (
        <ControlsTile
          size={size}
          settings={ctx.settings}
          isMac={ctx.isMac}
          isLinux={ctx.isLinux}
          hotkeyWarning={ctx.hotkeyWarning}
        />
      );
  }
}
