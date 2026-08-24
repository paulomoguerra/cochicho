import type { HistoryEntry, HistoryTotals } from "../../lib/ipc";
import { isRoomy, type TileSize } from "../layout";
import { DottedRing } from "../instruments";
import { Card, CardHeader, Stat } from "../ui";

function minutes(seconds: number): string {
  return seconds < 60 ? `${Math.round(seconds)}s` : `${Math.round(seconds / 60)}min`;
}

function startOfToday(): Date {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d;
}

function startOfWeek(): Date {
  const d = startOfToday();
  const day = d.getDay();
  const diff = day === 0 ? 6 : day - 1;
  d.setDate(d.getDate() - diff);
  return d;
}

export function StatsTile({
  size,
  entries,
  totals,
}: {
  size: TileSize;
  entries: HistoryEntry[];
  totals: HistoryTotals;
}) {
  const compact = !isRoomy(size);
  const today = startOfToday().getTime();
  const week = startOfWeek().getTime();
  const todayCount = entries.filter((e) => new Date(e.created_at).getTime() >= today).length;
  const weekCount = entries.filter((e) => new Date(e.created_at).getTime() >= week).length;
  const avgWords =
    entries.length === 0 ? "—" : `${Math.round(totals.total_words / Math.max(entries.length, 1))}W`;
  const corrections = entries.reduce(
    (sum, e) => sum + e.corrections.reduce((s, c) => s + c.count, 0),
    0,
  );

  return (
    <Card>
      <CardHeader number="03" title="STATS" />
      <div
        className="card-body"
        style={{
          flexDirection: "row",
          alignItems: "flex-start",
          gap: compact ? 10 : 16,
        }}
      >
        <DottedRing
          value={`${totals.entry_count}`}
          caption="DITADOS"
          size={compact ? 86 : 120}
        />
        <div
          style={{
            flex: 1,
            display: "grid",
            gridTemplateColumns: "1fr 1fr",
            gap: compact ? 6 : 10,
            minWidth: 0,
          }}
        >
          <Stat label="PALAVRAS" value={`${totals.total_words}`} compact={compact} />
          <Stat label="ÁUDIO" value={minutes(totals.total_seconds)} compact={compact} />
          <Stat
            label="HOJE"
            value={`${todayCount}`}
            accent={todayCount > 0}
            compact={compact}
          />
          <Stat label="SEMANA" value={`${weekCount}`} compact={compact} />
          <Stat label="MÉDIA" value={avgWords} compact={compact} />
          <Stat label="CORREÇÕES" value={`${corrections}`} compact={compact} />
        </div>
      </div>
    </Card>
  );
}
