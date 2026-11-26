/** A plot of positions without a map background: projection, grid clustering and a scale bar.
 * Coordinates are degrees times 100,000, as on the wire. */
export interface Point { id: number; lat: number; lon: number; status: number }
export interface Bounds { minLat: number; maxLat: number; minLon: number; maxLon: number }
export interface Cluster {
  x: number; y: number;                    // position in the view
  ids: number[]; status: number; lead: number;   // the most urgent status, and a member that has it
  bounds: Bounds | null;                   // what to show to take it apart; null if it cannot be
}

const SMALLEST_SPAN = 500;                 // about 500 m
const METERS_PER_UNIT = 111_320 / 100_000;

/** The area that holds all the points, with a margin. */
export function boundsOf(points: readonly Point[]): Bounds | null {
  if (points.length === 0) return null;
  let minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity;
  for (const p of points) {
    minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat);
    minLon = Math.min(minLon, p.lon); maxLon = Math.max(maxLon, p.lon);
  }
  const widen = (lo: number, hi: number): [number, number] => {
    const span = Math.max((hi - lo) * 1.2, SMALLEST_SPAN), middle = (lo + hi) / 2;
    return [middle - span / 2, middle + span / 2];
  };
  [minLat, maxLat] = widen(minLat, maxLat);
  [minLon, maxLon] = widen(minLon, maxLon);
  return { minLat, maxLat, minLon, maxLon };
}

/** Equirectangular about the middle latitude, one scale for both directions, centred. */
function frame(b: Bounds, width: number, height: number) {
  const squeeze = Math.max(Math.cos((((b.minLat + b.maxLat) / 2 / 100_000) * Math.PI) / 180), 0.05);
  const across = (b.maxLon - b.minLon) * squeeze, up = b.maxLat - b.minLat;
  const scale = Math.min(width / across, height / up);           // pixels per unit of latitude
  return { squeeze, scale, left: (width - across * scale) / 2, top: (height - up * scale) / 2 };
}

export function projector(b: Bounds, width: number, height: number) {
  const f = frame(b, width, height);
  return (lat: number, lon: number) => ({ x: f.left + (lon - b.minLon) * f.squeeze * f.scale, y: f.top + (b.maxLat - lat) * f.scale });
}

/** Points inside the view, joined by grid cell: at most one marker per cell, whatever their number. */
export function clusters(points: readonly Point[], view: Bounds, width: number, height: number, cell: number): Cluster[] {
  const to = projector(view, width, height);
  const cells = new Map<string, { x: number; y: number; members: Point[] }>();
  for (const p of points) {
    const { x, y } = to(p.lat, p.lon);
    if (x < 0 || x > width || y < 0 || y > height) continue;
    const key = `${Math.floor(x / cell)}:${Math.floor(y / cell)}`;
    let c = cells.get(key);
    if (!c) cells.set(key, (c = { x: 0, y: 0, members: [] }));
    c.x += x; c.y += y; c.members.push(p);
  }
  return [...cells.values()].map(({ x, y, members }) => {
    const lead = members.reduce((a, b) => (b.status < a.status || (b.status === a.status && b.id < a.id) ? b : a));
    const apart = members.some((p) => Math.abs(p.lat - lead.lat) > SMALLEST_SPAN / 20 || Math.abs(p.lon - lead.lon) > SMALLEST_SPAN / 20);
    const inner = apart ? boundsOf(members) : null;
    const smaller = inner && inner.maxLat - inner.minLat < view.maxLat - view.minLat - 1;
    return { x: x / members.length, y: y / members.length, ids: members.map((p) => p.id), status: lead.status, lead: lead.id,
      bounds: smaller || (inner && inner.maxLon - inner.minLon < view.maxLon - view.minLon - 1) ? inner : null };
  });
}

/** A round distance and its length on the plot, at most a quarter of the width. */
export function scaleBar(view: Bounds, width: number, height: number): { meters: number; pixels: number } {
  const metersPerPixel = METERS_PER_UNIT / frame(view, width, height).scale;
  const most = (width / 4) * metersPerPixel, magnitude = 10 ** Math.floor(Math.log10(most));
  const meters = [5, 2, 1].map((n) => n * magnitude).find((n) => n <= most) ?? magnitude;
  return { meters, pixels: meters / metersPerPixel };
}
