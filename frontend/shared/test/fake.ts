/** A scripted stand-in for the server, for the failure cases a real server cannot be told to
 * produce on demand. `integration.test.ts` runs the same engine against the real one. */
export interface Call { method: string; path: string; token: string | null; body: any }
export type Reply = { status: number; body: unknown } | "offline";

export function fakeServer(handler: (call: Call) => Reply) {
  const calls: Call[] = [];
  const fetch = async (input: string | URL | Request, init: RequestInit = {}) => {
    const url = new URL(String(input), "http://mina.test");
    const headers = new Headers(init.headers);
    const call: Call = {
      method: init.method ?? "GET",
      path: url.pathname + url.search,
      token: headers.get("authorization")?.replace(/^Bearer /, "") ?? null,
      body: typeof init.body === "string" ? JSON.parse(init.body) : undefined,
    };
    calls.push(call);
    const reply = handler(call);
    if (reply === "offline") throw new TypeError("fetch failed");
    return new Response(JSON.stringify(reply.body), { status: reply.status, headers: { "content-type": "application/json" } });
  };
  return { fetch: fetch as typeof globalThis.fetch, calls };
}
