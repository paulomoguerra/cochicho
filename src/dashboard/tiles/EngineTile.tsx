import { useEffect, useMemo, useState } from "react";
import {
  type EngineKind,
  type ModelStatus,
  type ModelResidenceStatus,
  type Settings,
  modelCatalog,
  modelDelete,
  modelDownload,
  modelLoadSelected,
  modelResidence,
  modelUnload,
  onDictationState,
  onModelProgress,
  settingsUpdate,
} from "../../lib/ipc";
import { isRoomy, type TileSize } from "../layout";
import { Card, CardHeader, DownloadBar, SegmentPicker, Stat } from "../ui";

function formatBytes(bytes: number): string {
  if (bytes <= 0) return "0 MB";
  const mb = bytes / 1_000_000;
  return mb >= 1000 ? `${(mb / 1000).toFixed(1)} GB` : `${Math.round(mb)} MB`;
}

function modelTitle(m: ModelStatus): string {
  return m.quant ? `${m.label} ${m.quant}` : m.label;
}

function effectiveEngine(settings: Settings, isMac: boolean): EngineKind {
  if (settings.engine) return settings.engine;
  return isMac ? "apple" : "whisper";
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
  const [residence, setResidence] = useState<ModelResidenceStatus | null>(null);
  const [residenceBusy, setResidenceBusy] = useState(false);
  const [residenceError, setResidenceError] = useState<string | null>(null);
  const roomy = isRoomy(size);
  const engine = effectiveEngine(settings, isMac);

  const refresh = () => {
    modelCatalog()
      .then(setCatalog)
      .catch(() => {});
    modelResidence()
      .then(setResidence)
      .catch(() => {});
  };

  useEffect(() => {
    refresh();
    const unsub = onModelProgress((p) => {
      if (busyName && p.name === busyName) setProgress(p.progress);
    });
    const stateUnsub = onDictationState((p) => {
      if (p.state === "idle" || p.state === "failed") {
        modelResidence().then(setResidence).catch(() => {});
      }
    });
    return () => {
      unsub.then((fn) => fn());
      stateUnsub.then((fn) => fn());
    };
  }, [busyName, engine, settings.parakeet_model, settings.whisper_model]);

  const engineOptions = useMemo(() => {
    const opts: { value: EngineKind; label: string }[] = [];
    if (isMac) opts.push({ value: "apple", label: "APPLE" });
    opts.push({ value: "parakeet", label: "PARAKEET" });
    opts.push({ value: "whisper", label: "WHISPER" });
    return opts;
  }, [isMac]);

  const setEngine = (next: EngineKind) => {
    setShowingDownloads(false);
    setResidenceError(null);
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

  const toggleResidence = async () => {
    if (residenceBusy) return;
    setResidenceBusy(true);
    setResidenceError(null);
    try {
      const selectedModel =
        engine === "apple"
          ? settings.language
          : engine === "whisper"
            ? settings.whisper_model
            : settings.parakeet_model;
      const isLoaded =
        residence?.loaded_engine === engine && residence.loaded_model === selectedModel;
      setResidence(isLoaded ? await modelUnload() : await modelLoadSelected());
    } catch (e) {
      setResidenceError(String(e));
    } finally {
      setResidenceBusy(false);
    }
  };

  const whisperModels = catalog.filter((m) => m.engine === "whisper");
  const parakeetModels = catalog.filter((m) => m.engine === "parakeet");
  const selectedModel =
    engine === "apple"
      ? settings.language
      : engine === "whisper"
        ? settings.whisper_model
        : settings.parakeet_model;
  const selectedLoaded =
    residence?.loaded_engine === engine && residence.loaded_model === selectedModel;

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
                models={parakeetModels}
                busyName={busyName}
                progress={progress}
                failed={failed}
                onSelect={(name) =>
                  void settingsUpdate({ engine: "parakeet", parakeet_model: name })
                }
                onDownload={(name) =>
                  void download("parakeet", name, () =>
                    settingsUpdate({ engine: "parakeet", parakeet_model: name }),
                  )
                }
                onDelete={(name) => void remove("parakeet", name)}
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

        {!showingDownloads && (
          <ResidenceFooter
            downloaded={
              engine === "apple"
                ? true
                : engine === "whisper"
                ? whisperModels.some((model) => model.name === settings.whisper_model && model.downloaded)
                : parakeetModels.some((model) => model.name === settings.parakeet_model && model.downloaded)
            }
            unloadedLabel={engine === "apple" ? "MODELO DO SISTEMA" : "BAIXADO · NO DISCO"}
            loaded={selectedLoaded}
            busy={residenceBusy}
            error={residenceError}
            onToggle={() => void toggleResidence()}
          />
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
    </>
  );
}

function ParakeetSection({
  size,
  settings,
  models,
  busyName,
  progress,
  failed,
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
  onSelect: (name: string) => void;
  onDownload: (name: string) => void;
  onDelete: (name: string) => void;
}) {
  const selected = models.find((m) => m.name === settings.parakeet_model) ?? models[0];
  const visible = models;

  if (size === "small") {
    return (
      <>
        <div style={{ flex: 1 }} />
        <StatusLine text={selected ? modelTitle(selected) : "PARAKEET"} />
      </>
    );
  }

  return (
    <>
      <span className="muted">MODELO</span>
      <ModelCatalogList
        models={visible}
        selectedName={settings.parakeet_model}
        busyName={busyName}
        progress={progress}
        failed={failed}
        compact
        onSelect={onSelect}
        onDownload={onDownload}
        onDelete={onDelete}
      />
      {busyName && <DownloadBar fraction={progress} />}
      {selected && <ModelDetail model={selected} />}
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
  onSelect: (name: string) => void;
  onDownload: (name: string) => void;
  onDelete: (name: string) => void;
}) {
  const visible = models.filter((m) => !m.english_only || settings.language === "en-US");
  const selected = visible.find((m) => m.name === settings.whisper_model);

  if (size === "small") {
    return (
      <>
        <div style={{ flex: 1 }} />
        <StatusLine text={selected ? modelTitle(selected) : settings.whisper_model} />
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
      <ModelCatalogList
        models={visible}
        selectedName={settings.whisper_model}
        busyName={busyName}
        progress={progress}
        failed={failed}
        onSelect={onSelect}
        onDownload={onDownload}
        onDelete={onDelete}
      />
      {busyName && <DownloadBar fraction={progress} />}
      {selected && <ModelDetail model={selected} />}
    </>
  );
}

function ResidenceFooter({
  downloaded,
  unloadedLabel,
  loaded,
  busy,
  error,
  onToggle,
}: {
  downloaded: boolean;
  unloadedLabel: string;
  loaded: boolean;
  busy: boolean;
  error: string | null;
  onToggle: () => void;
}) {
  return (
    <div className="residence-wrap">
      <div className="residence-footer">
        <StatusLine
          text={busy ? "CARREGANDO…" : loaded ? "CARREGADO · EM RAM" : downloaded ? unloadedLabel : "NÃO BAIXADO"}
          dim={!loaded}
        />
        {downloaded && !busy && (
          <button
            type="button"
            className={`residence-action${loaded ? " loaded" : ""}`}
            onClick={onToggle}
          >
            {loaded ? "DESCARREGAR" : "CARREGAR"}
          </button>
        )}
      </div>
      {error && <span className="residence-error">{error}</span>}
    </div>
  );
}

function ModelCatalogList({
  models,
  selectedName,
  busyName,
  progress,
  failed,
  compact,
  onSelect,
  onDownload,
  onDelete,
}: {
  models: ModelStatus[];
  selectedName: string;
  busyName: string | null;
  progress: number;
  failed: string | null;
  compact?: boolean;
  onSelect: (name: string) => void;
  onDownload: (name: string) => void;
  onDelete: (name: string) => void;
}) {
  const [showAll, setShowAll] = useState(!!compact);
  const hidden = models.filter(
    (m) => !(m.recommended || m.downloaded || m.name === selectedName),
  );
  const visible = showAll
    ? models
    : models.filter((m) => m.recommended || m.downloaded || m.name === selectedName);

  const groups: { family: string; items: ModelStatus[] }[] = [];
  for (const m of visible) {
    const last = groups[groups.length - 1];
    if (last && last.family === m.family) last.items.push(m);
    else groups.push({ family: m.family, items: [m] });
  }

  const showFamily = groups.length > 1;

  return (
    <>
      <div className="row-list">
        {groups.map((g) => (
          <div key={g.family}>
            {showFamily && <div className="model-family">{g.family.replace("-", " ")}</div>}
            {g.items.map((m) => {
              const selected = selectedName === m.name;
              const downloading = busyName === m.name;
              return (
                <button
                  key={m.name}
                  type="button"
                  className={`row model-row${selected ? " selected" : ""}${m.downloaded && !selected ? " ready" : ""}`}
                  onClick={() => {
                    if (m.downloaded) onSelect(m.name);
                    else onDownload(m.name);
                  }}
                >
                  <span className="model-title">{modelTitle(m)}</span>
                  {m.recommended ? <span className="model-rec">REC</span> : null}
                  <span className="model-meta">{m.languages}</span>
                  <span className="model-meta">
                    {m.downloaded
                      ? formatBytes(m.bytes_on_disk || m.approx_bytes)
                      : `~${formatBytes(m.approx_bytes)}`}
                  </span>
                  {downloading ? (
                    <span className="model-meta" style={{ color: "var(--accent)" }}>
                      {Math.round(progress * 100)}%
                    </span>
                  ) : failed === m.name ? (
                    <span className="model-meta" style={{ color: "var(--accent)" }}>
                      ERRO
                    </span>
                  ) : selected ? (
                    <span style={{ color: "var(--accent)" }}>✓</span>
                  ) : !m.downloaded ? (
                    <span className="model-meta">BAIXAR</span>
                  ) : null}
                  {m.downloaded && (
                    <span
                      role="button"
                      tabIndex={0}
                      className="row-btn model-delete"
                      title={`Apagar ${modelTitle(m)} do disco`}
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
        ))}
      </div>
      {!compact && hidden.length > 0 && (
        <button type="button" className="seg-btn" onClick={() => setShowAll((v) => !v)}>
          {showAll ? "MENOS" : `TODOS (${models.length})`}
        </button>
      )}
    </>
  );
}

function ModelDetail({ model }: { model: ModelStatus }) {
  const ram =
    model.ram_mb >= 1000
      ? `~${(model.ram_mb / 1000).toFixed(1)} GB RAM`
      : `~${model.ram_mb} MB RAM`;
  const disk = `~${formatBytes(model.approx_bytes)}`;
  return (
    <div className="model-detail">
      <p className="model-detail-blurb">{model.blurb}</p>
      <div className="model-meta">
        {model.languages}
        {model.quant ? ` · ${model.quant}` : ""}
        {` · ${disk}`}
        {` · ${ram}`}
        {model.english_only ? " · só EN" : ""}
      </div>
      <div className="model-scores">
        <Score label="VEL" value={model.speed} />
        <Score label="QUAL" value={model.quality} />
      </div>
    </div>
  );
}

function Score({ label, value }: { label: string; value: number }) {
  return (
    <span className="score">
      <span className="score-label">{label}</span>
      {Array.from({ length: 5 }, (_, i) => (
        <span key={i} className={`score-dot${i < value ? " on" : ""}`} />
      ))}
    </span>
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
              <span style={{ flex: 1, fontSize: 9 }}>{modelTitle(m)}</span>
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
