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

/** First-run Linux: Whisper only (Parakeet ainda é stub — volta quando sherpa-onnx linkar). */
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

  // tiny / base / small — bons pra ditado sem baixar GB no 1º run
  const options = catalog
    .filter((m) =>
      ["openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small"].includes(m.name),
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
            const mb = Math.round(m.approx_bytes / 1_000_000);
            return (
              <button
                key={m.name}
                type="button"
                disabled={!!busyName}
                onClick={() => void pick(m.engine, m.name)}
                style={{
                  textAlign: "left",
                  padding: "12px 14px",
                  borderRadius: 12,
                  border: "1px solid var(--card-border)",
                  background: active ? "rgba(255,69,0,0.12)" : "transparent",
                  color: "var(--ink)",
                  cursor: busyName ? "wait" : "pointer",
                  opacity: busyName && !active ? 0.4 : 1,
                }}
              >
                <div style={{ fontSize: 12, fontWeight: 600, letterSpacing: 0.5 }}>
                  {m.engine === "parakeet" ? "PARAKEET" : "WHISPER"} · {m.name}
                </div>
                <div style={{ fontSize: 10, color: "var(--ink-dim)", marginTop: 4 }}>
                  ~{mb} MB
                  {m.downloaded ? " · baixado" : ""}
                </div>
                {active && (
                  <div
                    style={{
                      marginTop: 10,
                      height: 4,
                      borderRadius: 2,
                      background: "rgba(255,255,255,0.08)",
                      overflow: "hidden",
                    }}
                  >
                    <div
                      style={{
                        width: `${Math.round(progress * 100)}%`,
                        height: "100%",
                        background: "var(--ok)",
                        transition: "width 120ms linear",
                      }}
                    />
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
