/-!
# The stored schema

MINA's tables as data. The emitter writes them as `schema.sql` and as a startup check that the
database really has this layout, so generated code never runs against tables it was not derived
for.

`events` is append-only: `seq` is assigned by the server and only grows, `eid` is the
client-chosen identifier that makes submissions idempotent, and `vis` separates the public
stream (0) from responder-only rows (1). `incidents` holds the one projection that transition
checks need.
-/
namespace Mina.Schema

inductive Ty where | integer | blob | text
  deriving Repr, DecidableEq

def Ty.sql : Ty → String
  | .integer => "INTEGER"
  | .blob => "BLOB"
  | .text => "TEXT"

structure Column where
  name : String
  ty : Ty
  /-- `INTEGER PRIMARY KEY`: the column is the rowid. -/
  rowid : Bool := false
  /-- Column constraints, as SQL. -/
  constraint : String := ""
  deriving Repr

structure Table where
  name : String
  cols : List Column
  deriving Repr

structure Index where
  name : String
  table : String
  keys : List String
  deriving Repr

/-- Longest report or alert text, in characters. -/
def maxBodyChars : Nat := 280

def events : Table := ⟨"events", [
  { name := "seq", ty := .integer, rowid := true },
  { name := "eid", ty := .blob, constraint := "NOT NULL UNIQUE CHECK (length(eid) = 16)" },
  { name := "region", ty := .integer, constraint := "NOT NULL" },
  { name := "vis", ty := .integer, constraint := "NOT NULL CHECK (vis IN (0, 1))" },
  { name := "kind", ty := .integer, constraint := "NOT NULL" },
  { name := "incident", ty := .integer },
  { name := "category", ty := .integer },
  { name := "status", ty := .integer },
  { name := "actor", ty := .integer, constraint := "NOT NULL" },
  { name := "ts", ty := .integer, constraint := "NOT NULL" },
  { name := "at", ty := .integer },
  { name := "lat", ty := .integer },
  { name := "lon", ty := .integer },
  { name := "body", ty := .text, constraint := s!"CHECK (length(body) <= {maxBodyChars})" }]⟩

def incidents : Table := ⟨"incidents", [
  { name := "id", ty := .integer, rowid := true },
  { name := "owner", ty := .integer, constraint := "NOT NULL" },
  { name := "region", ty := .integer, constraint := "NOT NULL" },
  { name := "category", ty := .integer, constraint := "NOT NULL" },
  { name := "status", ty := .integer, constraint := "NOT NULL" },
  { name := "updated_seq", ty := .integer, constraint := "NOT NULL" }]⟩

def tables : List Table := [events, incidents]

/-- Entries are (region, vis, rowid): one ordered range per region and visibility. -/
def eventsByRegion : Index := ⟨"events_region_vis", "events", ["region", "vis"]⟩

def indexes : List Index := [eventsByRegion]

end Mina.Schema
