/** Whether the server can be reached, as far as this device knows. */
export type Link = "online" | "offline" | "unreachable";

export function createLink(send: typeof fetch = (input, init) => fetch(input, init)) {
  let reached = true;
  const listeners = new Set<() => void>();
  const set = (value: boolean) => {
    if (reached !== value) {
      reached = value;
      listeners.forEach((f) => f());
    }
  };
  /** fetch that remembers whether the server answered. */
  const watched: typeof fetch = async (input, init) => {
    try {
      const response = await send(input, init);
      set(true);
      return response;
    } catch (error) {
      set(false);
      throw error;
    }
  };
  return {
    fetch: watched,
    state: (): Link => (!navigator.onLine ? "offline" : reached ? "online" : "unreachable"),
    watch(changed: () => void): () => void {
      listeners.add(changed);
      addEventListener("online", changed);
      addEventListener("offline", changed);
      return () => {
        listeners.delete(changed);
        removeEventListener("online", changed);
        removeEventListener("offline", changed);
      };
    },
  };
}
