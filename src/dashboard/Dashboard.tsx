import { type MouseEvent, useCallback, useEffect, useMemo, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
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
  hotkeyStatus,
  onDictationState,
  onDictionaryChanged,
  onHistoryChanged,
  onHotkeyAvailable,
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

function startHeaderDrag(event: MouseEvent<HTMLElement>) {
  if (event.button !== 0) return;
  const target = event.target;
  if (
    target instanceof Element &&
    target.closest("button, a, input, select, textarea, [role='button']")
  ) {
    return;
  }
  if (!("__TAURI_INTERNALS__" in window)) return;
  event.preventDefault();
  void getCurrentWindow().startDragging();
}

function describeIpcError(reason: unknown): string {
  if (reason instanceof Error && reason.message) return reason.message;
  if (typeof reason === "string" && reason.trim()) return reason;
  if (reason && typeof reason === "object") {
    try {
      const serialized = JSON.stringify(reason);
      if (serialized && serialized !== "{}") return serialized;
    } catch {
      // Fall through to the stable user-facing message below.
    }
  }
  return "Verifique se o app está aberto corretamente e tente novamente.";
}

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
  const [bootstrapError, setBootstrapError] = useState<string | null>(null);
  const [dataWarning, setDataWarning] = useState<string | null>(null);
  const [retryCount, setRetryCount] = useState(0);
  const [editingLayout, setEditingLayout] = useState(false);
  const [dragged, setDragged] = useState<TileId | null>(null);
  const [didReorder, setDidReorder] = useState(false);

  const isMac = platform.startsWith("macos");
  const isLinux = platform.startsWith("linux");

  const refreshDictionary = useCallback(() => {
    dictionaryList()
      .then(setEntries)
      .catch((reason) => {
        setDataWarning(`Dicionário: ${describeIpcError(reason)}`);
      });
  }, []);

  const refreshHistory = useCallback(() => {
    historyList()
      .then(setHistory)
      .catch((reason) => {
        setDataWarning(`Histórico: ${describeIpcError(reason)}`);
      });
    historyTotals()
      .then(setTotals)
      .catch((reason) => {
        setDataWarning(`Estatísticas: ${describeIpcError(reason)}`);
      });
  }, []);

  useEffect(() => {
    let cancelled = false;
    setSettings(null);
    setBootstrapError(null);
    setDataWarning(null);

    // These calls define whether the dashboard can render a truthful state.
    // Fail the bootstrap visibly instead of leaving the previous spinner on
    // screen forever.
    Promise.all([settingsGet(), dictationState(), platformInfo(), hotkeyStatus()])
      .then(([nextSettings, nextState, nextPlatform, nextHotkey]) => {
        if (cancelled) return;
        setSettings(nextSettings);
        setState(nextState.state);
        setError(nextState.error);
        setTranscript(nextState.transcript);
        setPlatform(nextPlatform);
        setHotkeyWarning(nextHotkey);
      })
      .catch((reason) => {
        if (!cancelled) setBootstrapError(describeIpcError(reason));
      });

    refreshDictionary();
    refreshHistory();

    const unlisteners = [
      onDictationState((p) => {
        setState(p.state);
        setError(p.error);
      }),
      onTranscript((p) => setTranscript(p.text)),
      onHotkeyUnavailable(setHotkeyWarning),
      onHotkeyAvailable(() => setHotkeyWarning(null)),
      onSettingsChanged(setSettings),
      onDictionaryChanged(refreshDictionary),
      onHistoryChanged(refreshHistory),
    ].map((listener) =>
      listener.catch((reason) => {
        console.warn("Eko Nami: falha ao acompanhar estado", reason);
        return () => {};
      }),
    );
    return () => {
      cancelled = true;
      unlisteners.forEach((u) => {
        void u.then((fn) => fn()).catch(() => {});
      });
    };
  }, [refreshDictionary, refreshHistory, retryCount]);

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

  if (bootstrapError) {
    return (
      <div
        className="dash"
        role="alert"
        style={{
          display: "flex",
          minHeight: "100%",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <div className="card" style={{ width: "100%", maxWidth: 520, height: "auto" }}>
          <div className="card-header">
            <span className="card-num">!</span>
            <span className="card-title">NÃO FOI POSSÍVEL CARREGAR</span>
          </div>
          <div className="card-body">
            <p style={{ margin: 0, color: "var(--accent)", fontSize: 12, lineHeight: 1.5 }}>
              {bootstrapError}
            </p>
            <button
              type="button"
              className="pill prominent"
              onClick={() => setRetryCount((count) => count + 1)}
            >
              TENTAR DE NOVO
            </button>
          </div>
        </div>
      </div>
    );
  }

  if (!settings) {
    return <div className="dash muted" role="status" aria-live="polite">CARREGANDO…</div>;
  }

  return (
    <div className="dash">
      {dataWarning && (
        <div
          role="status"
          style={{
            display: "flex",
            alignItems: "center",
            gap: 10,
            marginBottom: 12,
            padding: "8px 10px",
            border: "1px solid color-mix(in srgb, var(--accent) 34%, var(--card-border))",
            borderRadius: 10,
            color: "var(--accent)",
            fontSize: 10,
            lineHeight: 1.4,
          }}
        >
          <span style={{ flex: 1 }}>{dataWarning}</span>
          <PillButton
            onClick={() => {
              setDataWarning(null);
              refreshDictionary();
              refreshHistory();
            }}
          >
            RECARREGAR
          </PillButton>
        </div>
      )}
      <header className="dash-header" onMouseDown={startHeaderDrag}>
        <div className="dash-brand-block">
          <div className="dash-brand">E K O   N A M I</div>
          <div className="dash-tagline">VOICE → TEXT · 100% LOCAL</div>
        </div>
        <div className="dash-drag-zone" aria-hidden="true" />
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
