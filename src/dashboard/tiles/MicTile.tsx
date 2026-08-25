import { useEffect, useState } from "react";
import {
  type DictationState,
  dictationToggle,
  onAudioLevel,
} from "../../lib/ipc";
import { isRoomy, type TileSize } from "../layout";
import { DotWaveform } from "../instruments";
import { Card, CardHeader, PillButton, Stat } from "../ui";

function stateLabel(state: DictationState): string {
  switch (state) {
    case "idle":
      return "IDLE";
    case "starting":
      return "ARMING";
    case "listening":
      return "REC ●";
    case "finishing":
      return "PROC…";
    case "failed":
      return "ERR";
    default:
      return "IDLE";
  }
}

export function MicTile({
  size,
  state,
  error,
  transcript,
  hotkeyName,
  hotkeyWarning,
}: {
  size: TileSize;
  state: DictationState;
  error: string | null;
  transcript: string;
  hotkeyName: string;
  hotkeyWarning: string | null;
}) {
  const [levels, setLevels] = useState<number[]>(() => Array.from({ length: 40 }, () => 0));
  const [actionError, setActionError] = useState<string | null>(null);
  const active = state === "listening" || state === "starting";
  const busy = state === "starting" || state === "finishing";
  const roomy = isRoomy(size);

  useEffect(() => {
    const unsub = onAudioLevel((level) => {
      setLevels((prev) => {
        const next = [...prev, level];
        return next.length > 80 ? next.slice(next.length - 80) : next;
      });
    });
    return () => {
      unsub.then((fn) => fn());
    };
  }, []);

  useEffect(() => {
    if (state !== "starting") return;
    let step = 0;
    const timer = window.setInterval(() => {
      step += 1;
      const level = 0.18 + (Math.sin(step * 0.75) + 1) * 0.08;
      setLevels((prev) => [...prev.slice(-79), level]);
    }, 90);
    return () => window.clearInterval(timer);
  }, [state]);

  let display = actionError ?? transcript;
  if (state === "failed" && error) display = error;
  else if (!transcript) display = active ? "..." : "Segure a tecla e fale.";

  return (
    <Card>
      <CardHeader
        number="01"
        title="MIC"
        trailing={stateLabel(state)}
        trailingAccent={active}
      />
      <div className="card-body">
        {size !== "small" && (
          <p
            style={{
              margin: 0,
              fontSize: 15,
              lineHeight: 1.35,
              color: transcript && state !== "failed" ? "var(--ink)" : "var(--ink-faint)",
              display: "-webkit-box",
              WebkitLineClamp: roomy ? 5 : 2,
              WebkitBoxOrient: "vertical",
              overflow: "hidden",
              minHeight: 40,
            }}
          >
            {display}
          </p>
        )}

        <div style={{ height: roomy ? 88 : size === "small" ? 44 : 56, flex: roomy ? 1 : undefined }}>
          <DotWaveform levels={levels} rows={roomy ? 9 : 7} idle={!active} />
        </div>

        <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: "auto" }}>
          <PillButton
            prominent
            disabled={busy}
            onClick={() => {
              setActionError(null);
              void dictationToggle().catch((reason) => setActionError(String(reason)));
            }}
          >
            {busy ? "…" : active ? "PARAR" : "GRAVAR"}
          </PillButton>
          <div style={{ flex: 1 }} />
          {size !== "small" && <Stat label="TECLA" value={hotkeyName} compact />}
        </div>

        {hotkeyWarning && (
          <p style={{ margin: 0, fontSize: 10, color: "var(--ink-dim)" }}>
            hotkey: {hotkeyWarning}
          </p>
        )}
      </div>
    </Card>
  );
}
