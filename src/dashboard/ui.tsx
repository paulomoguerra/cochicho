import type { ReactNode } from "react";

export function Card({ children }: { children: ReactNode }) {
  return <div className="card">{children}</div>;
}

export function CardHeader({
  number,
  title,
  trailing,
  trailingAccent,
}: {
  number: string;
  title: string;
  trailing?: string;
  trailingAccent?: boolean;
}) {
  return (
    <div className="card-header">
      <span className="card-num">{number}</span>
      <span className="card-title">{title}</span>
      {trailing != null && (
        <span className={`card-trailing${trailingAccent ? " accent" : ""}`}>{trailing}</span>
      )}
    </div>
  );
}

export function PillButton({
  children,
  onClick,
  prominent,
  disabled,
}: {
  children: ReactNode;
  onClick?: () => void;
  prominent?: boolean;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      className={`pill${prominent ? " prominent" : ""}`}
      onClick={onClick}
      disabled={disabled}
    >
      {children}
    </button>
  );
}

export function SegmentPicker<T extends string>({
  options,
  value,
  onChange,
}: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
}) {
  return (
    <div className="seg">
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          className={`seg-btn${value === o.value ? " on" : ""}`}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function FlagRow({
  label,
  on,
  onChange,
}: {
  label: string;
  on: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <button type="button" className="flag" onClick={() => onChange(!on)}>
      <span>{label}</span>
      <span className={`flag-val${on ? " on" : ""}`}>{on ? "ON" : "OFF"}</span>
    </button>
  );
}

export function Stat({
  label,
  value,
  accent,
  compact,
}: {
  label: string;
  value: string;
  accent?: boolean;
  compact?: boolean;
}) {
  return (
    <div className={`stat${compact ? " compact" : ""}`}>
      <span className="stat-label">{label}</span>
      <span className={`stat-value${accent ? " accent" : ""}`}>{value}</span>
    </div>
  );
}

export function DownloadBar({ fraction }: { fraction: number }) {
  return (
    <div className="download-bar">
      <span style={{ width: `${Math.round(Math.min(1, Math.max(0, fraction)) * 100)}%` }} />
    </div>
  );
}
