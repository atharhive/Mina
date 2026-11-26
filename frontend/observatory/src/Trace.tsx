/** A small line chart of the recent values of one measurement. */
export function Trace({ title, values, format }: { title: string; values: number[]; format: (v: number) => string }) {
  const top = Math.max(...values, 0) || 1;
  const points = values.map((v, i) => `${values.length === 1 ? 300 : (i / (values.length - 1)) * 300},${58 - (v / top) * 54}`).join(" ");
  const last = values.at(-1);
  return (
    <figure className="border border-line bg-panel p-3">
      <figcaption className="flex justify-between text-sm"><span className="text-muted">{title}</span><span>{last === undefined ? "—" : format(last)}</span></figcaption>
      <svg viewBox="0 0 300 60" preserveAspectRatio="none" role="img" aria-label={`${title}: ${last === undefined ? "no data" : format(last)}, highest ${format(top)}`} className="mt-2 h-16 w-full">
        <line x1="0" y1="58" x2="300" y2="58" className="stroke-line" strokeWidth="1" vectorEffect="non-scaling-stroke" />
        {values.length > 1 && <polyline points={points} fill="none" className="stroke-trace" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />}
      </svg>
      <p className="text-right text-xs text-muted">scale 0 to {format(top)}</p>
    </figure>
  );
}
