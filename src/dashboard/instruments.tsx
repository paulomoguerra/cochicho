import { useEffect, useRef } from "react";

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
  const columns = 36;

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
          if (isLit && level > 0.6) ctx.fillStyle = "#ff4500";
          else if (isLit) ctx.fillStyle = "rgba(237,232,224,0.85)";
          else ctx.fillStyle = row === mid ? "rgba(255,255,255,0.14)" : "rgba(255,255,255,0.07)";
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
  }, [levels, rows, idle]);

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
      ctx.fillStyle = "rgba(237,232,224,0.8)";
      ctx.beginPath();
      ctx.arc(x, y, 1.6, 0, Math.PI * 2);
      ctx.fill();
    }
  }, [size]);

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
