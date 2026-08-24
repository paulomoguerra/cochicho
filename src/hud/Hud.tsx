import { useEffect, useRef, useState } from "react";
import {
  DictationState,
  onAudioLevel,
  onDictationState,
  onTranscript,
} from "../lib/ipc";

const BARS = 24;

/**
 * HUD mínimo do M1: dot-matrix de nível de áudio + estado + transcript ao vivo.
 * Os 3 tamanhos e o acabamento visual chegam no M5.
 */
export default function Hud() {
  const [state, setState] = useState<DictationState>("idle");
  const [error, setError] = useState<string | null>(null);
  const [text, setText] = useState("");
  const [levels, setLevels] = useState<number[]>(() => Array(BARS).fill(0));
  const frame = useRef(0);

  useEffect(() => {
    const unlisteners = [
      onDictationState((p) => {
        setState(p.state);
        setError(p.error);
      }),
      onTranscript((p) => setText(p.text)),
      // Nível chega a ~60fps; amostra 1 a cada 4 para o dot-matrix.
      onAudioLevel((level) => {
        frame.current = (frame.current + 1) % 4;
        if (frame.current !== 0) return;
        setLevels((prev) => [...prev.slice(1), level]);
      }),
    ];
    return () => {
      unlisteners.forEach((u) => u.then((fn) => fn()));
    };
  }, []);

  const active = state === "listening" || state === "starting";

  return (
    <div
      style={{
        height: "100%",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 10,
        background: "rgba(19, 18, 17, 0.92)",
        border: "1px solid var(--card-border)",
        borderRadius: 16,
        padding: "12px 18px",
        overflow: "hidden",
      }}
    >
      <div style={{ display: "flex", gap: 3, alignItems: "flex-end", height: 28 }}>
        {levels.map((level, i) => (
          <div
            key={i}
            style={{
              width: 4,
              height: active ? 4 + level * 24 : 4,
              borderRadius: 2,
              background:
                state === "failed"
                  ? "var(--accent)"
                  : level > 0.02
                    ? "var(--ok)"
                    : "var(--ink-faint)",
              transition: "height 90ms linear",
            }}
          />
        ))}
      </div>

      <div
        style={{
          fontSize: 11,
          color: state === "failed" ? "var(--accent)" : "var(--ink-dim)",
          maxWidth: "100%",
          whiteSpace: "nowrap",
          overflow: "hidden",
          textOverflow: "ellipsis",
        }}
      >
        {state === "failed"
          ? (error ?? "erro")
          : state === "starting"
            ? "preparando…"
            : state === "finishing"
              ? "finalizando…"
              : text || "ouvindo…"}
      </div>
    </div>
  );
}
