import Mina.Domain

/-!
# Reference queries

The SQL that defines what the server returns. Faster plans derived later must give the same
rows. `?1` is the region, `?2` the client's cursor and `?3` the row limit.
-/
namespace Mina.Query

/-- The columns of a synchronised event, in response order. -/
def eventColumns : String := "seq, kind, ts, incident, category, status, body, lat, lon, at"

def visible (vis : Nat) : String :=
  s!"SELECT {eventColumns} FROM events WHERE region = ?1 AND vis = {vis} AND seq > ?2"

/-- The public stream of a region. -/
def syncPublic : String := visible 0 ++ " ORDER BY seq LIMIT ?3"

/-- Everything in a region: the two ordered ranges, merged by sequence number. -/
def syncAll : String := visible 0 ++ " UNION ALL " ++ visible 1 ++ " ORDER BY 1 LIMIT ?3"

/-- The newest sequence number. -/
def head : String := "SELECT coalesce(max(seq), 0) FROM events"

/-- An incident with the report that opened it. -/
def incident : String :=
  "SELECT i.region, i.category, i.status, i.updated_seq, i.owner, e.ts, e.at, e.body, e.lat, e.lon " ++
  "FROM incidents i JOIN events e ON e.seq = i.id WHERE i.id = ?1"

/-- The newest sequence number of every stream (`Db.headOf`), read once at startup. -/
def heads : String := "SELECT region, vis, max(seq) FROM events GROUP BY region, vis"

/-! ## Writes

Statements the writer runs inside the batch transaction. -/

/-- The stored row of an event id. -/
def byEid : String := "SELECT seq, incident, actor FROM events WHERE eid = ?1"

/-- `seq` is assigned here, in the writing transaction; a new report opens the incident of the
same number. The newest number is read by a subquery of its own: written as
`SELECT max(seq) + 1 FROM events` inside the source, SQLite scans a whole index on every insert
(`tests/plans.sh`). -/
def eventInsert : String :=
  "INSERT INTO events (seq, eid, region, vis, kind, incident, category, status, actor, ts, at, lat, lon, body) " ++
  s!"SELECT s, ?1, ?2, ?3, ?4, CASE WHEN ?4 = {Domain.Kind.sosCreated.code} THEN s ELSE ?5 END, " ++
  "?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13 " ++
  "FROM (SELECT coalesce((SELECT max(seq) FROM events), 0) + 1 AS s) WHERE true RETURNING seq, incident"

def incidentInsert : String :=
  "INSERT INTO incidents (id, owner, region, category, status, updated_seq) VALUES (?1, ?2, ?3, ?4, ?5, ?1)"

def incidentState : String := "SELECT region, category, status FROM incidents WHERE id = ?1"

def incidentUpdate : String := "UPDATE incidents SET status = ?2, updated_seq = ?3 WHERE id = ?1"

/-- Every statement the server prepares, apart from the health check. -/
def all : List String :=
  [syncPublic, syncAll, head, incident, heads, byEid, eventInsert, incidentInsert, incidentState, incidentUpdate]

end Mina.Query
