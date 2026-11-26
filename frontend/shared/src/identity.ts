import type { Session } from "./api";
import { ROLE } from "./protocol";

export interface Responder extends Session { role: number; regions: number[] }

/** Reads an issued responder or admin token for what the interface needs to know. Nothing here
 * verifies the signature: the server does that on every request. */
export function readToken(token: string, nowSeconds: number): Responder {
  let claims: { sub?: unknown; role?: unknown; rg?: unknown; exp?: unknown };
  try {
    const part = token.trim().split(".");
    if (part.length !== 3) throw new Error();
    claims = JSON.parse(atob(part[1]!.replace(/-/g, "+").replace(/_/g, "/")));
  } catch {
    throw new Error("This is not a MINA token.");
  }
  const { sub, role, rg, exp } = claims;
  if (typeof sub !== "string" || typeof exp !== "number" || (role !== ROLE.responder && role !== ROLE.admin))
    throw new Error("This is not a responder or admin token.");
  if (exp <= nowSeconds) throw new Error("This token has expired.");
  const regions = typeof rg === "string" ? rg.split(",").map(Number) : [];
  if (role === ROLE.responder && regions.length === 0) throw new Error("This responder token names no region.");
  return { token: token.trim(), sub, role, regions, exp };
}
