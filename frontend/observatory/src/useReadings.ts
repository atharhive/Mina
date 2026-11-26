import { MinaApi, rates, type Metrics, type Rates } from "@mina/shared";
import { useEffect, useState } from "react";

const EVERY_MS = 2000;
const KEPT = 90;                              // three minutes

export interface Reading { at: number; metrics: Metrics; rates: Rates | null }
export interface Readings { history: Reading[]; problem: string | null; refused: boolean }

const api = new MinaApi();

/** Asks the server for its measurements every two seconds while the page is visible. */
export function useReadings(token: string): Readings {
  const [state, setState] = useState<Readings>({ history: [], problem: null, refused: false });
  useEffect(() => {
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;
    let previous: { at: number; metrics: Metrics } | undefined;
    const tick = async () => {
      if (stopped) return;
      if (document.visibilityState === "visible") {
        const reply = await api.metrics(token);
        const at = performance.now();
        if (stopped) return;
        if (reply.ok) {
          let change: Rates | null = null;
          try { if (previous) change = rates(previous.metrics, reply.value, (at - previous.at) / 1000); } catch { /* restarted */ }
          previous = { at, metrics: reply.value };
          const reading = { at: Date.now(), metrics: reply.value, rates: change };
          setState((s) => ({ history: [...s.history.slice(-(KEPT - 1)), reading], problem: null, refused: false }));
        } else {
          previous = undefined;
          setState((s) => ({ ...s, problem: reply.failure === "offline" ? "No answer from the server" : reply.message, refused: reply.failure === "auth" || reply.failure === "rejected" }));
        }
      }
      timer = setTimeout(tick, EVERY_MS);
    };
    void tick();
    return () => { stopped = true; clearTimeout(timer); };
  }, [token]);
  return state;
}
