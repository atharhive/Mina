import { MinaApi, MinaDb, SyncEngine, createLink } from "@mina/shared";

export const connection = createLink();
export const db = new MinaDb("mina-command");
export const engine = new SyncEngine(db, new MinaApi("", connection.fetch), undefined, { identity: "given", page: 256 });

/** Remove everything this device holds: reports contain other people's words and places. */
export async function signOut() {
  await db.delete();
  location.reload();
}
