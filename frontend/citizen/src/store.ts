import { MinaApi, MinaDb, SyncEngine } from "@mina/shared";

export type Link = "online" | "offline" | "unreachable";

let reached = true;
const listeners = new Set<() => void>();
const tell = () => listeners.forEach((f) => f());

/** fetch that remembers whether the server answered. */
const watched: typeof fetch = async (input, init) => {
  try {
    const response = await fetch(input, init);
    if (!reached) { reached = true; tell(); }
    return response;
  } catch (error) {
    if (reached) { reached = false; tell(); }
    throw error;
  }
};

export const db = new MinaDb();
export const engine = new SyncEngine(db, new MinaApi("", watched));

export const link = (): Link => (!navigator.onLine ? "offline" : reached ? "online" : "unreachable");
export function watchLink(changed: () => void): () => void {
  listeners.add(changed);
  addEventListener("online", changed);
  addEventListener("offline", changed);
  return () => {
    listeners.delete(changed);
    removeEventListener("online", changed);
    removeEventListener("offline", changed);
  };
}

/** Synchronise now and then every few seconds while the page is visible; at once when the
 * network returns. The interval is spread so that many devices do not ask together. */
export function keepSynchronised(region: number): () => void {
  let timer: ReturnType<typeof setTimeout>;
  let stopped = false;
  const tick = async () => {
    clearTimeout(timer);
    if (stopped) return;
    if (navigator.onLine && document.visibilityState === "visible") await engine.run(region).catch((e) => console.error(e));
    if (!stopped) timer = setTimeout(tick, 6000 + Math.random() * 4000);
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
