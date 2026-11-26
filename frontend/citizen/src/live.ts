import { liveQuery } from "@mina/shared";
import { useEffect, useState } from "react";

/** The result of a database query, kept current as the database changes. */
export function useLive<T>(query: () => Promise<T>, deps: readonly unknown[]): T | undefined {
  const [value, setValue] = useState<T>();
  useEffect(() => {
    const subscription = liveQuery(query).subscribe({ next: (v) => setValue(() => v), error: (e) => console.error(e) });
    return () => subscription.unsubscribe();
  }, deps);
  return value;
}
