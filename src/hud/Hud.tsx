import { useEffect, useRef, useState } from "react";
import {
  DictationState,
  type HudSize,
  dictationState,
  onAudioLevel,
  onDictationState,
  onSettingsChanged,
  onTranscript,
  settingsGet,
} from "../lib/ipc";
import { DotWaveform } from "../dashboard/instruments";

const BARS = 24;

/**
 * HUD mínimo do M1: dot-matrix de nível de áudio + estado + transcript ao vivo.
 * Os 3 tamanhos e o acabamento visual chegam no M5.
 */
export default function Hud() {
  const [state, setState] = useState<DictationState>("idle");
  const [error, setError] = useState<string | null>(null);
  const [text, setText] = useState("");
  const [isFinal, setIsFinal] = useState(false);
  const [levels, setLevels] = useState<number[]>(() => Array(BARS).fill(0));
  const [hudSize, setHudSize] = useState<HudSize>("medium");
  const [hotkeyName, setHotkeyName] = useState("—");
  const frame = useRef(0);

  useEffect(() => {
    const unlisteners = [
      onDictationState((p) => {
        setState(p.state);
        setError(p.error);
        if (p.state === "starting") {
          setText("");
          setIsFinal(false);
        }
      }),
      onTranscript((p) => {
        setText(p.text);
        setIsFinal(p.is_final);
      }),
      onAudioLevel((level) => {
        frame.current = (frame.current + 1) % 4;
        if (frame.current !== 0) return;
        setLevels((prev) => [...prev.slice(1), level]);
      }),
      onSettingsChanged((settings) => {
        setHudSize(settings.hud_size);
        setHotkeyName(settings.hotkey.display_name);
      }),
    ];
    settingsGet()
      .then((settings) => {
        setHudSize(settings.hud_size);
        setHotkeyName(settings.hotkey.display_name);
      })
      .catch(() => {});
    dictationState()
      .then((current) => {
        setState(current.state);
        setError(current.error);
        setText(current.transcript);
      })
      .catch(() => {});
    return () => {
      unlisteners.forEach((u) => u.then((fn) => fn()));
    };
  }, []);

  useEffect(() => {
    if (state !== "starting") return;
    let step = 0;
    const timer = window.setInterval(() => {
      step += 1;
      const level = 0.18 + (Math.sin(step * 0.75) + 1) * 0.08;
      setLevels((prev) => [...prev.slice(-23), level]);
    }, 90);
    return () => window.clearInterval(timer);
  }, [state]);

  const active = state === "listening" || state === "starting";
  const label =
    state === "starting"
      ? "PREPARANDO"
      : state === "listening"
        ? "OUVINDO"
        : state === "finishing"
          ? "TRANSCREVENDO"
          : state === "failed"
            ? "ERRO"
            : "";

  const display =
    state === "failed" ? (error ?? "erro") : text || (active || state === "finishing" ? "…" : "");

  return (
    <div className={`hud-shell hud-${hudSize} hud-${state}`}>
      <div className="hud-card-header">
        <span className="card-num">01</span>
        <span className="card-title">MIC</span>
        <span className={`card-trailing${active ? " accent" : ""}`}>{label}</span>
      </div>

      {hudSize !== "minimal" && (
        <LiveTranscript text={display} live={active && !isFinal} />
      )}

      <div className="hud-dot-wave">
        <DotWaveform
          levels={levels}
          rows={hudSize === "large" ? 7 : 5}
          idle={!active}
        />
      </div>

      {hudSize === "large" && (
        <div className="hud-footer">
          <span className="hud-status-dot" />
          <span>100% LOCAL</span>
          <span className="hud-hotkey">{hotkeyName}</span>
        </div>
      )}
    </div>
  );
}

function LiveTranscript({ text, live }: { text: string; live: boolean }) {
  if (!text || text === "…") {
    return (
      <div className="hud-transcript hud-transcript-placeholder">
        Ouvindo<span className="hud-live-caret" />
      </div>
    );
  }
  const words = text.trim().split(/\s+/);
  const tailStart = Math.max(0, words.length - 5);
  const stable = words.slice(0, tailStart).join(" ");
  const tail = words.slice(tailStart).join(" ");
  return (
    <div className="hud-transcript" aria-live="polite">
      {stable && <span className="hud-transcript-stable">{stable} </span>}
      <span className="hud-transcript-current">{tail}</span>
      {live && <span className="hud-live-caret" />}
    </div>
  );
}
