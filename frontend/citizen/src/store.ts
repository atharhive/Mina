import { MinaApi, MinaDb, SyncEngine, createLink } from "@mina/shared";

export const connection = createLink();
export const db = new MinaDb();
export const engine = new SyncEngine(db, new MinaApi("", connection.fetch));
