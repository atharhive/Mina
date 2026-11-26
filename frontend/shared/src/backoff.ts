const FIRST_MS = 1000;
const MAX_MS = 60_000;

/** Delay before retry number `attempts` (1, 2, ...): the window doubles up to a minute, and the
 * delay falls in its upper half, so that devices reconnecting together spread out. */
export function backoffMs(attempts: number, random: () => number): number {
  const window = Math.min(MAX_MS, FIRST_MS * 2 ** attempts);
  return window / 2 + random() * (window / 2);
}
