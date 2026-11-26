import { ROLE, readToken } from "@mina/shared";
import { useState, type FormEvent } from "react";
import { Live } from "./Live";
import { Proved, Recorded } from "./Recorded";
import { useReadings } from "./useReadings";

/** The token is held in memory only: closing the page forgets it. */
export function App() {
  const [token, setToken] = useState("");
  return (
    <div className="mx-auto max-w-6xl space-y-8 px-4 pb-10">
      <header className="flex items-baseline justify-between border-b border-line py-3">
        <h1 className="text-lg font-semibold tracking-tight">MINA Observatory</h1>
        {token && <button className="text-sm underline" onClick={() => setToken("")}>Disconnect</button>}
      </header>
      {token ? <Connected token={token} /> : <Connect onToken={setToken} />}
      <Recorded />
      <Proved />
    </div>
  );
}

function Connect({ onToken }: { onToken: (t: string) => void }) {
  const [value, setValue] = useState("");
  const [problem, setProblem] = useState("");
  function connect(event: FormEvent) {
    event.preventDefault();
    try {
      const who = readToken(value, Date.now() / 1000);
      if (who.role !== ROLE.admin) throw new Error("Only an admin token can read measurements.");
      onToken(who.token);
    } catch (error) {
      setProblem(error instanceof Error && error.message.includes("admin token can read") ? error.message : "Only an admin token can read measurements.");
    }
  }
  return (
    <form onSubmit={connect} className="max-w-md space-y-2 border border-line bg-panel p-4">
      <label className="block"><span>Admin token</span>
        <input type="password" autoComplete="off" value={value} onChange={(e) => { setValue(e.target.value); setProblem(""); }}
          className="mt-1 w-full border border-line bg-base p-2 font-mono text-sm" /></label>
      {problem && <p role="alert" className="text-wait">{problem}</p>}
      <button type="submit" disabled={!value} className="border border-ink px-4 py-2 font-semibold disabled:opacity-40">Connect</button>
      <p className="text-sm text-muted">Live measurements come from this server. Recorded results below need no token.</p>
    </form>
  );
}

function Connected({ token }: { token: string }) {
  const readings = useReadings(token);
  const last = readings.history.at(-1);
  const seen = last ? new Date(last.at).toLocaleTimeString() : null;
  return (
    <section aria-label="Live measurements" className="space-y-3">
      <h2 className="border-b border-line pb-1 font-semibold">Live measurements <span className="font-normal text-muted">· this server, every 2 s</span></h2>
      <p role="status" aria-label="Connection" className={`text-sm ${readings.problem ? "font-semibold text-wait" : "text-muted"}`}>
        {readings.problem ? `${readings.problem}${seen ? `. Figures below are from ${seen} and are not current.` : "."}` : seen ? `Read at ${seen}.` : "Connecting."}
      </p>
      <Live readings={readings} />
    </section>
  );
}
