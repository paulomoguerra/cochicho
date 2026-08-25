import { useEffect, useState } from "react";
import {
  type EngineKind,
  type ModelStatus,
  modelCatalog,
  modelDownload,
  onModelProgress,
  settingsUpdate,
} from "../lib/ipc";
import { PillButton } from "./ui";

function formatBytes(bytes: number): string {
  if (bytes <= 0) return "0 MB";
  const mb = bytes / 1_000_000;
  return mb >= 1000 ? `${(mb / 1000).toFixed(1)} GB` : `${Math.round(mb)} MB`;
}

function modelTitle(m: ModelStatus): string {
  return m.quant ? `${m.label} ${m.quant}` : m.label;
}

/** First-run Linux: Whisper tiny/base/small (Q5) com ficha de cada um. */
export default function EnginePicker({ onDone }: { onDone: () => void }) {
  const [catalog, setCatalog] = useState<ModelStatus[]>([]);
  const [busyName, setBusyName] = useState<string | null>(null);
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    modelCatalog()
      .then((list) =>
        setCatalog(
          list.filter((m) => m.engine === "whisper" && !m.english_only),
        ),
      )
      .catch((e) => setError(String(e)));
    const unsub = onModelProgress((p) => setProgress(p.progress));
    return () => {
      unsub.then((fn) => fn());
    };
  }, []);

  const pick = async (engine: EngineKind, name: string) => {
    if (busyName) return;
    setError(null);
    setBusyName(name);
    setProgress(0);
    try {
      await modelDownload(engine, name);
      await settingsUpdate({ engine: "whisper", whisper_model: name });
      onDone();
    } catch (e) {
      setError(String(e));
      setBusyName(null);
      setProgress(0);
    }
  };

  const options = catalog
    .filter((m) =>
      [
        "openai_whisper-tiny-q5_1",
        "openai_whisper-base-q5_1",
        "openai_whisper-small-q5_1",
      ].includes(m.name),
    )
    .sort((a, b) => a.approx_bytes - b.approx_bytes);

  return (
    <div
      className="dash"
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        minHeight: "100%",
      }}
    >
      <div className="card" style={{ width: "100%", maxWidth: 520 }}>
        <div className="card-header">
          <span className="card-num">00</span>
          <span className="card-title">ENGINE</span>
        </div>
        <div className="card-body">
          {options.map((m) => {
            const active = busyName === m.name;
            return (
              <button
                key={m.name}
                type="button"
                className={`picker-option${active ? " active" : ""}`}
                disabled={!!busyName}
                onClick={() => void pick(m.engine, m.name)}
                style={{
                  cursor: busyName ? "wait" : "pointer",
                  opacity: busyName && !active ? 0.4 : 1,
                }}
              >
                <div style={{ fontSize: 12, fontWeight: 600, letterSpacing: 0.5 }}>
                  WHISPER · {modelTitle(m)}
                </div>
                <div style={{ fontSize: 10, color: "var(--ink-dim)", marginTop: 4 }}>
                  ~{formatBytes(m.approx_bytes)} · {m.languages} · RAM ~{m.ram_mb} MB
                  {m.quant ? ` · ${m.quant}` : ""}
                  {m.downloaded ? " · baixado" : ""}
                </div>
                <p className="model-detail-blurb" style={{ marginTop: 6 }}>
                  {m.blurb}
                </p>
                <div className="model-scores" style={{ marginTop: 8 }}>
                  <span className="score">
                    <span className="score-label">VEL</span>
                    {Array.from({ length: 5 }, (_, i) => (
                      <span key={`v${i}`} className={`score-dot${i < m.speed ? " on" : ""}`} />
                    ))}
                  </span>
                  <span className="score">
                    <span className="score-label">QUAL</span>
                    {Array.from({ length: 5 }, (_, i) => (
                      <span key={`q${i}`} className={`score-dot${i < m.quality ? " on" : ""}`} />
                    ))}
                  </span>
                </div>
                {active && (
                  <div
                    className="download-bar"
                    style={{ marginTop: 10, height: 4 }}
                  >
                    <span style={{ width: `${Math.round(progress * 100)}%` }} />
                  </div>
                )}
              </button>
            );
          })}
          {error && (
            <p style={{ color: "var(--accent)", fontSize: 11, margin: 0 }}>{error}</p>
          )}
          {options.length === 0 && !error && (
            <PillButton disabled>…</PillButton>
          )}
        </div>
      </div>
    </div>
  );
}
