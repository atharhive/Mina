import { useState, type FormEvent } from "react";
import { engine } from "./store";

export function SignIn() {
  const [token, setToken] = useState("");
  const [problem, setProblem] = useState("");
  async function signIn(event: FormEvent) {
    event.preventDefault();
    try {
      await engine.signIn(token);
    } catch (error) {
      setProblem(error instanceof Error ? error.message : "Could not sign in.");
    }
  }
  return (
    <main className="mx-auto max-w-md space-y-4 p-6">
      <h1 className="text-xl font-semibold tracking-tight">MINA Command</h1>
      <form onSubmit={signIn} className="space-y-3 border border-line bg-panel p-4">
        <label className="block">
          <span className="font-medium">Access token</span>
          <input type="password" autoComplete="off" value={token} onChange={(e) => { setToken(e.target.value); setProblem(""); }}
            className="mt-1 w-full border border-line bg-base p-2 font-mono text-sm" />
        </label>
        {problem && <p role="alert" className="text-alarm">{problem}</p>}
        <button type="submit" disabled={!token} className="w-full bg-ink py-2 font-semibold text-base disabled:opacity-40">Sign in</button>
      </form>
      <p className="text-sm text-muted">Tokens are issued offline by the operator of this server.</p>
    </main>
  );
}
