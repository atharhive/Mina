import type { SyncEngine } from "./sync";

/** Synchronise now and then every few seconds while the page is visible, and at once when the
 * network returns. The interval is spread so that many devices do not ask together. */
export function keepSynchronised(engine: SyncEngine, regions: readonly number[], everyMs = 6000, spreadMs = 4000): () => void {
  let timer: ReturnType<typeof setTimeout>;
  let stopped = false;
  const tick = async () => {
    clearTimeout(timer);
    if (stopped) return;
    if (navigator.onLine && document.visibilityState === "visible") await engine.run(...regions).catch((e) => console.error(e));
    if (!stopped) timer = setTimeout(tick, everyMs + Math.random() * spreadMs);
  };
  const now = () => void engine.retryNow().then(tick);
  addEventListener("online", now);
  document.addEventListener("visibilitychange", tick);
  now();                                                   // the app was opened
  return () => {
    stopped = true;
    clearTimeout(timer);
    removeEventListener("online", now);
    document.removeEventListener("visibilitychange", tick);
  };
}
