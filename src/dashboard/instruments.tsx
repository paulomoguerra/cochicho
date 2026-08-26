import { useEffect, useRef, useState } from "react";

export const DOT_WAVEFORM_COLUMNS = 36;
export const DOT_WAVEFORM_SPEED = 0.7;
export const DOT_WAVEFORM_EVENTS_PER_STEP = 4;
export const DOT_WAVEFORM_STARTING_STEP_MS = Math.round(90 / DOT_WAVEFORM_SPEED);

function useThemeTick() {
  const [tick, setTick] = useState(0);
  useEffect(() => {
    const el = document.documentElement;
    const obs = new MutationObserver(() => setTick((n) => n + 1));
    obs.observe(el, { attributes: true, attributeFilter: ["data-theme"] });
    return () => obs.disconnect();
  }, []);
  return tick;
}

/** Colunas de pontos acesos do meio pra fora — port de `DotWaveform`. */
export function DotWaveform({
  levels,
  rows = 7,
  idle,
}: {
  levels: number[];
  rows?: number;
  idle: boolean;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const columns = DOT_WAVEFORM_COLUMNS;
  const themeTick = useThemeTick();

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const parent = canvas.parentElement;
    if (!parent) return;

    const draw = () => {
      const w = parent.clientWidth;
      const h = parent.clientHeight;
      const dpr = window.devicePixelRatio || 1;
      canvas.width = Math.max(1, Math.floor(w * dpr));
      canvas.height = Math.max(1, Math.floor(h * dpr));
      canvas.style.width = `${w}px`;
      canvas.style.height = `${h}px`;
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);

      const styles = getComputedStyle(document.documentElement);
      const accent = styles.getPropertyValue("--accent").trim() || "#ff4500";
      const dotLit = styles.getPropertyValue("--dot-lit").trim() || "rgba(237,232,224,0.85)";
      const dotMid = styles.getPropertyValue("--dot-mid").trim() || "rgba(255,255,255,0.14)";
      const dotOff = styles.getPropertyValue("--dot-off").trim() || "rgba(255,255,255,0.07)";

      const gapX = w / columns;
      const gapY = h / rows;
      const radius = Math.min(gapX, gapY) * 0.28;
      const mid = Math.floor(rows / 2);

      for (let col = 0; col < columns; col++) {
        const index = levels.length - columns + col;
        const level = index >= 0 && index < levels.length ? levels[index]! : 0;
        const lit = idle ? 0 : Math.round(level * rows);

        for (let row = 0; row < rows; row++) {
          const distance = Math.abs(row - mid);
          const isLit = distance <= lit / 2 && lit > 0;
          const x = gapX * (col + 0.5);
          const y = gapY * (row + 0.5);
          if (isLit && level > 0.6) ctx.fillStyle = accent;
          else if (isLit) ctx.fillStyle = dotLit;
          else ctx.fillStyle = row === mid ? dotMid : dotOff;
          ctx.beginPath();
          ctx.arc(x, y, radius, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    };

    draw();
    const ro = new ResizeObserver(draw);
    ro.observe(parent);
    return () => ro.disconnect();
  }, [levels, rows, idle, themeTick]);

  return <canvas ref={ref} style={{ width: "100%", height: "100%", display: "block" }} />;
}

/** Anel pontilhado com valor no centro — port de `DottedRing`. */
export function DottedRing({
  value,
  caption,
  size = 86,
}: {
  value: string;
  caption: string;
  size?: number;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const themeTick = useThemeTick();

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.floor(size * dpr);
    canvas.height = Math.floor(size * dpr);
    canvas.style.width = `${size}px`;
    canvas.style.height = `${size}px`;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, size, size);

    const center = size / 2;
    const ringRadius = size / 2 - 6;
    const dots = 48;
    for (let i = 0; i < dots; i++) {
      const angle = (i / dots) * Math.PI * 2 - Math.PI / 2;
      const x = center + Math.cos(angle) * ringRadius;
      const y = center + Math.sin(angle) * ringRadius;
      ctx.fillStyle = getComputedStyle(document.documentElement)
        .getPropertyValue("--dot-lit")
        .trim() || "rgba(237,232,224,0.8)";
      ctx.beginPath();
      ctx.arc(x, y, 1.6, 0, Math.PI * 2);
      ctx.fill();
    }
  }, [size, themeTick]);

  return (
    <div style={{ position: "relative", width: size, height: size, flexShrink: 0 }}>
      <canvas ref={ref} />
      <div
        style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          gap: 2,
          pointerEvents: "none",
        }}
      >
        <span style={{ fontSize: 26, fontWeight: 500, color: "var(--ink)" }}>{value}</span>
        <span
          style={{
            fontSize: 9,
            letterSpacing: 1.5,
            color: "var(--ink-faint)",
            textTransform: "uppercase",
          }}
        >
          {caption}
        </span>
      </div>
    </div>
  );
}
