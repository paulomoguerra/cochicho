import { useMemo, useState } from "react";
import type { HistoryEntry } from "../../lib/ipc";
import { historyClear } from "../../lib/ipc";
import type { TileSize } from "../layout";
import { Card, CardHeader, PillButton } from "../ui";

function formatWhen(iso: string): string {
  const d = new Date(iso);
  const dd = String(d.getDate()).padStart(2, "0");
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  return `${dd}/${mm} ${hh}:${mi}`;
}

export function HistoryTile({
  size,
  entries,
  saveHistory,
}: {
  size: TileSize;
  entries: HistoryEntry[];
  saveHistory: boolean;
}) {
  const [query, setQuery] = useState("");
  const [copiedId, setCopiedId] = useState<string | null>(null);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return entries;
    return entries.filter((e) => e.corrected_text.toLowerCase().includes(q));
  }, [entries, query]);

  const copy = async (entry: HistoryEntry) => {
    try {
      await navigator.clipboard.writeText(entry.corrected_text);
      setCopiedId(entry.id);
      window.setTimeout(() => {
        setCopiedId((id) => (id === entry.id ? null : id));
      }, 1200);
    } catch {
      /* clipboard pode falhar sem foco */
    }
  };

  return (
    <Card>
      <CardHeader number="04" title="HISTÓRICO" trailing={`${entries.length}`} />
      <div className="card-body">
        {size !== "small" && (
          <div style={{ display: "flex", gap: 8 }}>
            <input
              className="field"
              placeholder="buscar…"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
            {entries.length > 0 && (
              <PillButton
                onClick={() => {
                  void historyClear();
                }}
              >
                LIMPAR
              </PillButton>
            )}
          </div>
        )}

        {!saveHistory && <span className="muted">SALVAR DESLIGADO</span>}

        {filtered.length === 0 ? (
          <div
            style={{
              flex: 1,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <span className="muted">
              {entries.length === 0 ? "NADA AINDA" : "NENHUM RESULTADO"}
            </span>
          </div>
        ) : (
          <div className="row-list" style={{ gap: 6 }}>
            {filtered.map((entry) => (
              <button
                key={entry.id}
                type="button"
                onClick={() => void copy(entry)}
                style={{
                  display: "block",
                  width: "100%",
                  textAlign: "left",
                  padding: 10,
                  border: "none",
                  borderRadius: 10,
                  background: "rgba(255,255,255,0.03)",
                  color: "var(--ink)",
                  cursor: "pointer",
                }}
              >
                <div
                  style={{
                    display: "flex",
                    gap: 8,
                    alignItems: "center",
                    marginBottom: 5,
                  }}
                >
                  <span style={{ fontSize: 9, color: "var(--ink-faint)" }}>
                    {formatWhen(entry.created_at)}
                  </span>
                  {size !== "small" && (
                    <span
                      style={{
                        fontSize: 8,
                        fontWeight: 500,
                        letterSpacing: 1,
                        color: "var(--ink-dim)",
                        padding: "2px 6px",
                        borderRadius: 999,
                        background: "rgba(255,255,255,0.06)",
                        textTransform: "uppercase",
                      }}
                    >
                      {entry.engine}
                    </span>
                  )}
                  <span style={{ flex: 1 }} />
                  <span
                    style={{
                      fontSize: 8,
                      fontWeight: 500,
                      letterSpacing: 1,
                      color: copiedId === entry.id ? "var(--ok)" : "var(--ink-faint)",
                    }}
                  >
                    {copiedId === entry.id
                      ? "COPIADO"
                      : `${entry.word_count}W · ${Math.round(entry.duration_seconds)}s`}
                  </span>
                </div>
                <div
                  style={{
                    fontSize: 11,
                    lineHeight: 1.4,
                    display: "-webkit-box",
                    WebkitLineClamp: size === "small" ? 1 : 3,
                    WebkitBoxOrient: "vertical",
                    overflow: "hidden",
                  }}
                >
                  {entry.corrected_text}
                </div>
              </button>
            ))}
          </div>
        )}
      </div>
    </Card>
  );
}
