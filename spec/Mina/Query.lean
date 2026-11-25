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

def all : List String := [syncPublic, syncAll, head]

end Mina.Query
