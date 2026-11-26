import { STATUS, boundsOf, clusters, scaleBar, type Bounds, type Cluster, type Incident } from "@mina/shared";
import { useMemo, useState, type KeyboardEvent } from "react";
import { CATEGORY_TEXT, STATUS_TEXT } from "./text";

const WIDTH = 600, HEIGHT = 360, CELL = 48;

/** Where the unresolved incidents are, relative to each other. There is no map behind them. */
export function PositionPlot({ incidents, selected, onSelect }: { incidents: Incident[]; selected: number | undefined; onSelect: (id: number) => void }) {
  const [zoom, setZoom] = useState<Bounds | null>(null);
  const open = useMemo(() => incidents.filter((i) => i.status !== STATUS.resolved), [incidents]);
  const points = useMemo(() => open.flatMap((i) => (i.lat === null || i.lon === null ? [] : [{ id: i.id, lat: i.lat, lon: i.lon, status: i.status }])), [open]);
  const view = zoom ?? boundsOf(points);
  const found = useMemo(() => (view ? clusters(points, view, WIDTH, HEIGHT, CELL) : []), [points, view?.minLat, view?.maxLat, view?.minLon, view?.maxLon]);
  const byId = useMemo(() => new Map(open.map((i) => [i.id, i])), [open]);
  const bar = view ? scaleBar(view, WIDTH, HEIGHT) : null;

  const label = (c: Cluster) =>
    c.ids.length === 1 ? `${CATEGORY_TEXT[byId.get(c.lead)!.category]}, ${STATUS_TEXT[c.status]!.toLowerCase()}`
      : `${c.ids.length} reports, the most urgent ${STATUS_TEXT[c.status]!.toLowerCase()}${c.bounds ? ": zoom in" : ""}`;
  const press = (c: Cluster) => (c.ids.length > 1 && c.bounds ? setZoom(c.bounds) : onSelect(c.lead));
  const key = (c: Cluster) => (e: KeyboardEvent) => {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); press(c); }
  };

  return (
    <section aria-label="Incident positions" className="space-y-1">
      <div className="flex items-baseline justify-between border-b border-line pb-1">
        <h2 className="font-semibold">Positions</h2>
        {zoom && <button onClick={() => setZoom(null)} className="text-sm underline">Show all</button>}
      </div>
      {view && bar ? (
        <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} className="w-full border border-line bg-panel" role="group" aria-label="Unresolved incidents by position">
          {found.map((c) => (
            <g key={c.lead} role="button" tabIndex={0} aria-label={label(c)} onClick={() => press(c)} onKeyDown={key(c)}
              className={`cursor-pointer ${c.status === STATUS.open ? "text-alarm" : "text-wait"}`}>
              <circle cx={c.x} cy={c.y} r={c.ids.length === 1 ? 8 : Math.min(22, 11 + Math.log2(c.ids.length) * 2)} fill="currentColor"
                stroke={selected !== undefined && c.ids.includes(selected) ? "var(--color-ink)" : "none"} strokeWidth="3" />
              {c.ids.length > 1 && <text x={c.x} y={c.y} textAnchor="middle" dominantBaseline="central" className="fill-base text-xs font-bold">{c.ids.length}</text>}
            </g>
          ))}
          <line x1="12" y1={HEIGHT - 12} x2={12 + bar.pixels} y2={HEIGHT - 12} stroke="var(--color-muted)" strokeWidth="2" />
          <text x="12" y={HEIGHT - 20} className="fill-muted text-xs">{bar.meters >= 1000 ? `${bar.meters / 1000} km` : `${bar.meters} m`}</text>
          <text x={WIDTH - 10} y="16" textAnchor="end" className="fill-muted text-xs">north ↑</text>
        </svg>
      ) : <p className="py-3 text-muted">No unresolved incident has shared a location.</p>}
      <p className="text-xs text-muted">Positions only, no map background. {open.length - points.length} unresolved without a location are in the list only.</p>
    </section>
  );
}
