export const whole = (v: number) => Math.round(v).toLocaleString("en-US");
export const one = (v: number) => v.toLocaleString("en-US", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
export const bytes = (v: number) =>
  v >= 1 << 30 ? `${one(v / (1 << 30))} GB` : v >= 1 << 20 ? `${one(v / (1 << 20))} MB` : v >= 1024 ? `${one(v / 1024)} KB` : `${whole(v)} B`;
export const share = (part: number, total: number) => (total > 0 ? `${Math.round((100 * part) / total)} %` : "—");
/** A histogram bound: the value was below it. */
export const below = (v: number | null, unit: string) => (v === null ? "—" : `< ${whole(v)} ${unit}`);
