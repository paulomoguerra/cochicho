import { useEffect, useMemo, useState } from "react";
import {
  type EngineKind,
  type ModelStatus,
  type ParakeetVersion,
  type Settings,
  modelCatalog,
  modelDelete,
  modelDownload,
  onModelProgress,
  settingsUpdate,
} from "../../lib/ipc";
import { isRoomy, type TileSize } from "../layout";
import { Card, CardHeader, DownloadBar, PillButton, SegmentPicker, Stat } from "../ui";

function formatBytes(bytes: number): string {
  if (bytes <= 0) return "0 MB";
  const mb = bytes / 1_000_000;
  return mb >= 1000 ? `${(mb / 1000).toFixed(1)} GB` : `${Math.round(mb)} MB`;
}

function whisperDisplay(name: string): string {
  return name
    .replace(/^openai_whisper-/, "")
    .replace(/^distil-whisper_/, "distil-")
    .toUpperCase();
}

function effectiveEngine(settings: Settings, isMac: boolean): EngineKind {
  if (settings.engine) return settings.engine;
  return isMac ? "apple" : "parakeet";
}

export function EngineTile({
  size,
  settings,
  isMac,
}: {
  size: TileSize;
  settings: Settings;
  isMac: boolean;
}) {
  const [catalog, setCatalog] = useState<ModelStatus[]>([]);
  const [showingDownloads, setShowingDownloads] = useState(false);
  const [busyName, setBusyName] = useState<string | null>(null);
  const [progress, setProgress] = useState(0);
  const [failed, setFailed] = useState<string | null>(null);
  const roomy = isRoomy(size);
  const engine = effectiveEngine(settings, isMac);

  const refresh = () => {
    modelCatalog()
      .then(setCatalog)
      .catch(() => {});
  };

  useEffect(() => {
    refresh();
    const unsub = onModelProgress((p) => {
      if (busyName && p.name === busyName) setProgress(p.progress);
    });
    return () => {
      unsub.then((fn) => fn());
    };
  }, [busyName]);

  const engineOptions = useMemo(() => {
    const opts: { value: EngineKind; label: string }[] = [];
    if (isMac) opts.push({ value: "apple", label: "APPLE" });
    opts.push({ value: "parakeet", label: "PARAKEET" }, { value: "whisper", label: "WHISPER" });
    return opts;
  }, [isMac]);

  const setEngine = (next: EngineKind) => {
    setShowingDownloads(false);
    void settingsUpdate({ engine: next });
  };

  const download = async (eng: EngineKind, name: string, thenSelect?: () => Promise<unknown>) => {
    if (busyName) return;
    setFailed(null);
    setBusyName(name);
    setProgress(0);
    try {
      await modelDownload(eng, name);
      if (thenSelect) await thenSelect();
      refresh();
    } catch {
      setFailed(name);
    } finally {
      setBusyName(null);
      setProgress(0);
    }
  };

  const remove = async (eng: EngineKind, name: string) => {
    try {
      await modelDelete(eng, name);
      refresh();
    } catch {
      /* ignore */
    }
  };

  const whisperModels = catalog.filter((m) => m.engine === "whisper");
  const parakeetModels = catalog.filter((m) => m.engine === "parakeet");
  const selectedParakeet =
    parakeetModels.find((m) =>
      settings.parakeet_version === "v2"
        ? m.name.includes("v2")
        : m.name.includes("v3"),
    ) ?? parakeetModels[0];

  return (
    <Card>
      <CardHeader number="02" title="ENGINE" />
      <div className="card-body">
        <div style={{ display: "flex", gap: 4, alignItems: "center", flexWrap: "wrap" }}>
          <SegmentPicker options={engineOptions} value={engine} onChange={setEngine} />
          {size !== "small" && (
            <button
              type="button"
              className={`seg-btn${showingDownloads ? " on" : ""}`}
              onClick={() => setShowingDownloads((v) => !v)}
            >
              ↓
            </button>
          )}
        </div>

        {showingDownloads && size !== "small" ? (
          <DownloadsPanel
            isMac={isMac}
            parakeet={parakeetModels.filter((m) => m.downloaded)}
            whisper={whisperModels.filter((m) => m.downloaded)}
            onDelete={remove}
          />
        ) : (
          <>
            {engine === "apple" && (
              <AppleSection size={size} settings={settings} roomy={roomy} />
            )}
            {engine === "parakeet" && (
              <ParakeetSection
                size={size}
                settings={settings}
                model={selectedParakeet}
                busyName={busyName}
                progress={progress}
                roomy={roomy}
                onVersion={(v) => void settingsUpdate({ parakeet_version: v })}
                onDownload={() => {
                  if (!selectedParakeet) return;
                  void download("parakeet", selectedParakeet.name, () =>
                    settingsUpdate({
                      engine: "parakeet",
                      parakeet_version: settings.parakeet_version,
                    }),
                  );
                }}
                onDelete={() => {
                  if (selectedParakeet) void remove("parakeet", selectedParakeet.name);
                }}
              />
            )}
            {engine === "whisper" && (
              <WhisperSection
                size={size}
                settings={settings}
                models={whisperModels}
                busyName={busyName}
                progress={progress}
                failed={failed}
                roomy={roomy}
                onSelect={(name) => void settingsUpdate({ engine: "whisper", whisper_model: name })}
                onDownload={(name) =>
                  void download("whisper", name, () =>
                    settingsUpdate({ engine: "whisper", whisper_model: name }),
                  )
                }
                onDelete={(name) => void remove("whisper", name)}
              />
            )}
          </>
        )}
      </div>
    </Card>
  );
}

function AppleSection({
  size,
  settings,
  roomy,
}: {
  size: TileSize;
  settings: Settings;
  roomy: boolean;
}) {
  return (
    <>
      {size !== "small" && (
        <>
          <span className="muted">IDIOMA</span>
          <SegmentPicker
            options={[
              { value: "pt-BR", label: "PT-BR" },
              { value: "en-US", label: "EN-US" },
            ]}
            value={settings.language}
            onChange={(language) => void settingsUpdate({ language })}
          />
        </>
      )}
      <div style={{ flex: 1 }} />
      {roomy && <PerfPlaceholder />}
      <StatusLine text={size === "small" ? "MODELO DO SISTEMA · NEURAL ENGINE" : "MODELO DO SISTEMA"} />
    </>
  );
}

function ParakeetSection({
  size,
  settings,
  model,
  busyName,
  progress,
  roomy,
  onVersion,
  onDownload,
  onDelete,
}: {
  size: TileSize;
  settings: Settings;
  model: ModelStatus | undefined;
  busyName: string | null;
  progress: number;
  roomy: boolean;
  onVersion: (v: ParakeetVersion) => void;
  onDownload: () => void;
  onDelete: () => void;
}) {
  const downloading = !!model && busyName === model.name;
  return (
    <>
      {size !== "small" && <span className="muted">VERSÃO</span>}
      <SegmentPicker
        options={[
          { value: "v3", label: "V3" },
          { value: "v2", label: "V2" },
        ]}
        value={settings.parakeet_version}
        onChange={onVersion}
      />
      <div style={{ flex: 1 }} />
      {roomy && <PerfPlaceholder />}
      {model?.downloaded ? (
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <StatusLine
            text={
              size === "small"
                ? `PARAKEET ${settings.parakeet_version.toUpperCase()} · LOCAL`
                : `PARAKEET ${settings.parakeet_version.toUpperCase()} · ${formatBytes(model.bytes_on_disk || model.approx_bytes)}`
            }
          />
          {size !== "small" && (
            <button type="button" className="row-btn" onClick={onDelete}>
              EXCLUIR
            </button>
          )}
        </div>
      ) : (
        <>
          <PillButton disabled={!!busyName} onClick={onDownload}>
            {downloading ? "BAIXANDO…" : "BAIXAR MODELO"}
          </PillButton>
          {downloading && <DownloadBar fraction={progress} />}
        </>
      )}
    </>
  );
}

function WhisperSection({
  size,
  settings,
  models,
  busyName,
  progress,
  failed,
  roomy,
  onSelect,
  onDownload,
  onDelete,
}: {
  size: TileSize;
  settings: Settings;
  models: ModelStatus[];
  busyName: string | null;
  progress: number;
  failed: string | null;
  roomy: boolean;
  onSelect: (name: string) => void;
  onDownload: (name: string) => void;
  onDelete: (name: string) => void;
}) {
  const visible = models.filter(
    (m) => !m.english_only || settings.language === "en-US",
  );

  if (size === "small") {
    return (
      <>
        <div style={{ flex: 1 }} />
        <StatusLine text={whisperDisplay(settings.whisper_model)} />
      </>
    );
  }

  return (
    <>
      <span className="muted">IDIOMA</span>
      <SegmentPicker
        options={[
          { value: "pt-BR", label: "PT-BR" },
          { value: "en-US", label: "EN-US" },
        ]}
        value={settings.language}
        onChange={(language) => void settingsUpdate({ language })}
      />
      <span className="muted">MODELO</span>
      <div className="row-list">
        {visible.map((m) => {
          const selected = settings.whisper_model === m.name;
          const downloading = busyName === m.name;
          return (
            <button
              key={m.name}
              type="button"
              className="row"
              style={{
                width: "100%",
                cursor: "pointer",
                border: "none",
                textAlign: "left",
                background: selected ? "rgba(255,255,255,0.06)" : "rgba(255,255,255,0.02)",
                color: selected ? "var(--accent)" : m.downloaded ? "var(--ink)" : "var(--ink-dim)",
                fontSize: 9,
                fontWeight: selected ? 600 : 400,
              }}
              onClick={() => {
                if (m.downloaded) onSelect(m.name);
                else onDownload(m.name);
              }}
            >
              <span style={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis" }}>
                {whisperDisplay(m.name)}
              </span>
              <span style={{ color: "var(--ink-faint)", fontSize: 8 }}>
                {m.downloaded
                  ? formatBytes(m.bytes_on_disk || m.approx_bytes)
                  : `~${formatBytes(m.approx_bytes)}`}
              </span>
              {downloading ? (
                <span style={{ color: "var(--accent)", fontSize: 8 }}>
                  {Math.round(progress * 100)}%
                </span>
              ) : failed === m.name ? (
                <span style={{ color: "var(--accent)", fontSize: 8 }}>ERRO</span>
              ) : selected ? (
                <span style={{ color: "var(--accent)" }}>✓</span>
              ) : !m.downloaded ? (
                <span style={{ color: "var(--ink-dim)", fontSize: 8 }}>BAIXAR</span>
              ) : null}
              {m.downloaded && (
                <span
                  role="button"
                  tabIndex={0}
                  className="row-btn"
                  onClick={(e) => {
                    e.stopPropagation();
                    onDelete(m.name);
                  }}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") {
                      e.stopPropagation();
                      onDelete(m.name);
                    }
                  }}
                >
                  ×
                </span>
              )}
            </button>
          );
        })}
      </div>
      {busyName && <DownloadBar fraction={progress} />}
      {roomy && <PerfPlaceholder />}
      <StatusLine text={whisperDisplay(settings.whisper_model)} />
    </>
  );
}

function DownloadsPanel({
  isMac,
  parakeet,
  whisper,
  onDelete,
}: {
  isMac: boolean;
  parakeet: ModelStatus[];
  whisper: ModelStatus[];
  onDelete: (engine: EngineKind, name: string) => void;
}) {
  const total =
    parakeet.reduce((s, m) => s + (m.bytes_on_disk || 0), 0) +
    whisper.reduce((s, m) => s + (m.bytes_on_disk || 0), 0);

  return (
    <div className="scroll-y" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      {isMac && (
        <div>
          <div className="muted">APPLE</div>
          <div className="row" style={{ marginTop: 4 }}>
            <span style={{ fontSize: 9 }}>SISTEMA</span>
          </div>
        </div>
      )}
      <Group
        title="PARAKEET"
        rows={parakeet}
        empty
        onDelete={(n) => onDelete("parakeet", n)}
      />
      <Group title="WHISPER" rows={whisper} empty onDelete={(n) => onDelete("whisper", n)} />
      <StatusLine text={`TOTAL EM DISCO: ${formatBytes(total)}`} dim />
    </div>
  );
}

function Group({
  title,
  rows,
  empty,
  onDelete,
}: {
  title: string;
  rows: ModelStatus[];
  empty: boolean;
  onDelete: (name: string) => void;
}) {
  return (
    <div>
      <div className="muted">{title}</div>
      <div style={{ display: "flex", flexDirection: "column", gap: 4, marginTop: 4 }}>
        {rows.length === 0 && empty ? (
          <div className="row">
            <span style={{ fontSize: 9, color: "var(--ink-faint)" }}>NENHUM</span>
          </div>
        ) : (
          rows.map((m) => (
            <div key={m.name} className="row">
              <span style={{ flex: 1, fontSize: 9 }}>{whisperDisplay(m.name)}</span>
              <span style={{ fontSize: 8, color: "var(--ink-faint)" }}>
                {formatBytes(m.bytes_on_disk || m.approx_bytes)}
              </span>
              <button type="button" className="row-btn" onClick={() => onDelete(m.name)}>
                ×
              </button>
            </div>
          ))
        )}
      </div>
    </div>
  );
}

function StatusLine({ text, dim }: { text: string; dim?: boolean }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
      <span
        style={{
          width: 6,
          height: 6,
          borderRadius: "50%",
          background: dim ? "var(--ink-dim)" : "var(--ok)",
          flexShrink: 0,
        }}
      />
      <span
        style={{
          fontSize: 8,
          letterSpacing: 1,
          color: "var(--ink-dim)",
          textTransform: "uppercase",
        }}
      >
        {text}
      </span>
    </div>
  );
}

/** Latência por engine depende de process_seconds — ainda não no HistoryEntry Rust. */
function PerfPlaceholder() {
  return (
    <div style={{ display: "flex", gap: 16 }}>
      <Stat label="ÚLTIMA" value="—" compact />
      <Stat label="MÉDIA" value="—" compact />
    </div>
  );
}
