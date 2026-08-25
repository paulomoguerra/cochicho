import { useState } from "react";
import {
  type DictionaryEntry,
  dictionaryAdd,
  dictionaryRemove,
  dictionaryRestoreDefaults,
  dictionaryToggle,
} from "../../lib/ipc";
import { Card, CardHeader, PillButton } from "../ui";

function newId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export function DictionaryTile({
  entries,
  dictionaryEnabled,
}: {
  entries: DictionaryEntry[];
  dictionaryEnabled: boolean;
}) {
  const [hear, setHear] = useState("");
  const [write, setWrite] = useState("");
  const active = entries.filter((e) => e.is_enabled).length;

  const add = () => {
    const w = write.trim();
    const h = hear.trim();
    if (!w) return;
    const entry: DictionaryEntry = h
      ? { id: newId(), kind: "correction", hear: h, write: w, is_enabled: true }
      : { id: newId(), kind: "term", hear: "", write: w, is_enabled: true };
    void dictionaryAdd(entry);
    setHear("");
    setWrite("");
  };

  return (
    <Card>
      <CardHeader number="05" title="DICIONÁRIO" trailing={`${active} ATIVAS`} />
      <div className="card-body">
        {!dictionaryEnabled && <span className="muted">CORREÇÃO DESLIGADA</span>}

        <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
          <input
            className="field"
            placeholder="ouvir…"
            value={hear}
            onChange={(e) => setHear(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") add();
            }}
          />
          <span style={{ color: "var(--accent)", fontSize: 11 }}>→</span>
          <input
            className="field"
            placeholder="escrever…"
            value={write}
            onChange={(e) => setWrite(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") add();
            }}
          />
          <PillButton prominent disabled={!write.trim()} onClick={add}>
            +
          </PillButton>
        </div>

        <div style={{ display: "flex", justifyContent: "flex-end" }}>
          <button
            type="button"
            className="row-btn"
            style={{ letterSpacing: 1 }}
            onClick={() => void dictionaryRestoreDefaults()}
          >
            PADRÃO
          </button>
        </div>

        <div className="row-list">
          {entries.map((entry) => (
            <div key={entry.id} className="row">
              {entry.kind === "correction" && (
                <>
                  <span
                    style={{
                      fontSize: 10,
                      color: entry.is_enabled ? "var(--ink-dim)" : "var(--ink-faint)",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      maxWidth: "35%",
                    }}
                  >
                    {entry.hear}
                  </span>
                  <span
                    style={{
                      fontSize: 9,
                      color: entry.is_enabled ? "var(--accent)" : "color-mix(in srgb, var(--accent) 30%, transparent)",
                    }}
                  >
                    →
                  </span>
                </>
              )}
              <span
                style={{
                  flex: 1,
                  fontSize: 10,
                  fontWeight: 500,
                  color: entry.is_enabled ? "var(--ink)" : "var(--ink-faint)",
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                }}
              >
                {entry.write}
              </span>
              <button
                type="button"
                className={`row-btn${entry.is_enabled ? " on" : ""}`}
                onClick={() => void dictionaryToggle(entry.id)}
              >
                {entry.is_enabled ? "ON" : "OFF"}
              </button>
              <button
                type="button"
                className="row-btn"
                onClick={() => void dictionaryRemove(entry.id)}
              >
                ×
              </button>
            </div>
          ))}
        </div>
      </div>
    </Card>
  );
}
