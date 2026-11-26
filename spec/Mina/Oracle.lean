import Lean.Data.Json
import Std.Data.HashMap
import Mina.Model
import Mina.Contract
import Mina.Domain
import Mina.Schema

/-!
# The oracle: what the server should answer, in Lean

An executable second reference beside the SQL. It applies submissions and answers reads using
the same definitions the theorems are about: the store is `Mina.Model.Db`, sequence numbers and
retries come from `Db.submit`, synchronisation from `Db.syncRef` and `Db.syncAllRef` (which
`syncPlan_eq` and `syncAllPlan_eq` prove equal to the native plans), and permissions, required
fields and status changes from `Mina.Domain`.

`tests/oracle.mjs` sends the same requests to this program and to the server and compares the
answers. What is written here and in C separately (and so what the comparison can catch) is the
order of the checks, the validation of each value, redaction and the shape of every answer.
Token verification and rate limits are not modelled.
-/
namespace Mina.Oracle
open Lean Mina.Domain Mina.Model

abbrev Reply := Nat × Json

def failure (status : Nat) (message : String) : Reply := (status, Json.mkObj [("error", .str message)])

def orNull {α} [ToJson α] : Option α → Json
  | none => .null
  | some x => toJson x

structure Actor where
  sub : Nat
  role : Role
  regions : List Nat

def Actor.inRegion (a : Actor) (r : Nat) : Bool := a.role == .admin || a.regions.contains r

/-- The columns of a stored event that do not decide which rows a read returns. -/
structure Row where
  kind : Nat
  incident : Option Nat
  category : Option Int
  status : Option Int
  actor : Nat
  at_ : Option Int
  lat : Option Int
  lon : Option Int
  body : Option String
  deriving Inhabited

structure Incident where
  owner : Nat
  region : Nat
  category : Int
  status : Int
  updated : Nat

structure State where
  db : Db := ⟨[]⟩
  rows : Std.HashMap Nat Row := {}
  incidents : Std.HashMap Nat Incident := {}

/-! ## Submissions -/

structure Submission where
  eid : Nat
  kind : Kind
  region : Option Int
  category : Option Int
  status : Option Int
  incident : Option Int
  lat : Option Int
  lon : Option Int
  at_ : Option Int
  body : Option String

/-- A JSON integer: no fraction. -/
def integer : Json → Option Int
  | .num ⟨m, 0⟩ => some m
  | _ => none

def within (lo hi : Int) (v : Option Int) : Option Int := v.filter fun x => lo ≤ x && x ≤ hi

def largest : Int := 999999999999999

/-- Whitespace as JavaScript's `trim` sees it. -/
def jsSpace (c : Char) : Bool :=
  let n := c.toNat
  (9 ≤ n && n ≤ 13) || n == 32 || n == 0xA0 || n == 0x1680 || (0x2000 ≤ n && n ≤ 0x200A) ||
  n == 0x2028 || n == 0x2029 || n == 0x202F || n == 0x205F || n == 0x3000 || n == 0xFEFF

def trimmed (s : String) : List Char := ((s.toList.dropWhile jsSpace).reverse.dropWhile jsSpace).reverse

/-- Thirty-two lower-case hexadecimal digits. -/
def eventId (s : String) : Option Nat :=
  let cs := s.toList
  if cs.length == 32 && cs.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')) then
    some (cs.foldl (fun n c => n * 16 + if c.isDigit then c.toNat - 48 else c.toNat - 87) 0)
  else none

def decode (who : Actor) (raw : String) : Except Reply Submission := do
  let j ← match Json.parse raw with
    | .ok (.obj o) => pure (Json.obj o)
    | _ => throw (failure 400 "invalid json")
  let get (name : String) : Option Json := (j.getObjVal? name).toOption
  let some eid := (match get "eid" with | some (.str s) => eventId s | _ => none)
    | throw (failure 400 "invalid event id")
  let code := (get "kind").bind integer
  let some kind := Kind.all.find? (fun k => code == some (Int.ofNat k.code))
    | throw (failure 400 "invalid kind")
  unless kind.roles.contains who.role do throw (failure 403 "not permitted")
  let present := Field.all.filter fun f => match f with
    | .location => (get "lat").isSome || (get "lon").isSome
    | f => (get f.name).isSome
  if present.any (fun f => !(kind.required ++ kind.optional).contains f) || kind.required.any (fun f => !present.contains f) then
    throw (failure 400 "missing or unexpected field")
  -- the value of a field that is present must be an integer in its range
  let number (name : String) (lo hi : Int) (message : String) : Except Reply (Option Int) :=
    match get name with
    | none => .ok none
    | some v => match within lo hi (integer v) with
      | some x => .ok (some x)
      | none => .error (failure 400 message)
  let region ← number "region" 1 maxRegion "invalid region"
  let category ← number "category" 1 (Int.ofNat ((Category.all.map Category.code).foldl Nat.max 0)) "invalid category"
  let status ← number "status" kind.statusRange.1 kind.statusRange.2 "invalid status"
  let incident ← number "incident" 1 largest "invalid incident"
  let lat := (get "lat").bind integer |> within (-maxLatitude) maxLatitude
  let lon := (get "lon").bind integer |> within (-maxLongitude) maxLongitude
  if present.contains .location && (lat.isNone || lon.isNone) then throw (failure 400 "invalid location")
  let at_ ← number "at" 0 maxTime "invalid time"
  let body ← match get "body" with
    | none => pure none
    | some (.str s) =>
      let text := trimmed s
      if text.any (fun c => c.toNat < 32 && c != '\n' && c != '\t') || text.length > Schema.maxBodyChars then
        throw (failure 400 "invalid body")
      pure (if text.isEmpty then none else some (String.ofList text))
    | some _ => throw (failure 400 "invalid body")
  if kind.required.contains .body && body.isNone then throw (failure 400 "invalid body")
  if let some r := region then
    if who.role != .citizen && !who.inRegion r.toNat then throw (failure 403 "region not authorized")
  return { eid, kind, region, category, status, incident, lat, lon, at_, body }

def storedBody (seq : Nat) (incident : Option Nat) (duplicate : Bool) : Json :=
  Json.mkObj ([("seq", toJson seq), ("incident", orNull incident)] ++ if duplicate then [("duplicate", .bool true)] else [])

/-- Append the event with `Db.submit` and record its other columns and the incident. -/
def store (st : State) (who : Actor) (s : Submission) (region : Nat) (category status : Option Int) : State × Reply :=
  let db := st.db.submit s.eid region (if s.kind.restricted then 1 else 0)
  let seq := db.lastSeq
  let incident := if s.kind == .sosCreated then some seq else s.incident.map Int.toNat
  let row : Row := { kind := s.kind.code, incident, category, status, actor := who.sub, at_ := s.at_,
                     lat := s.lat, lon := s.lon, body := s.body }
  let incidents :=
    if s.kind == .sosCreated then
      st.incidents.insert seq ⟨who.sub, region, category.getD 0, Domain.Status.open_.code, seq⟩
    else match incident.bind (fun i => (st.incidents[i]?).map (i, ·)) with
      | some (i, old) => st.incidents.insert i { old with status := status.getD old.status, updated := seq }
      | none => st.incidents
  ({ db, rows := st.rows.insert seq row, incidents }, (201, storedBody seq incident false))

def submit (st : State) (who : Actor) (s : Submission) : State × Reply :=
  match st.db.events.find? (·.eid == s.eid) with
  | some e =>
    let row := st.rows.getD e.seq default
    if row.actor != who.sub then (st, failure 409 "event id already used")
    else (st, (200, storedBody e.seq row.incident true))
  | none =>
    if s.kind.required.contains .incident then
      match s.incident.bind (fun i => st.incidents[i.toNat]?) with
      | none => (st, failure 404 "no such incident")
      | some inc =>
        if !who.inRegion inc.region then (st, failure 404 "no such incident") else
        let target : Int := match s.kind.fixedStatus with
          | some t => t.code
          | none => s.status.getD 0
        if transitions.any (fun t => t.kind == s.kind && (t.source.code : Int) == inc.status && (t.target.code : Int) == target) then
          store st who s inc.region (some inc.category) (some target)
        else (st, failure 409 "invalid transition")
    else store st who s (s.region.getD 0).toNat s.category s.status

/-! ## Reads -/

/-- A query value: an optional minus sign and digits, sixteen characters at most. -/
def decimal (s : String) : Option Int :=
  let cs := s.toList
  let digits := if cs.head? == some '-' then cs.drop 1 else cs
  if cs.length ≤ 16 && !digits.isEmpty && digits.all Char.isDigit then
    let n : Int := digits.foldl (fun n c => n * 10 + (c.toNat - 48)) 0
    some (if cs.head? == some '-' then -n else n)
  else none

def sync (st : State) (who : Actor) (query : Json) : Reply :=
  let param (name : String) (lo hi : Int) (fallback : Option Int) : Option Int :=
    match query.getObjVal? name with
    | .ok (.str s) => within lo hi (decimal s)
    | _ => fallback
  match param "region" 1 maxRegion none, param "after" 0 largest (some 0),
        param "limit" 1 Contract.syncMaxLimit (some Contract.syncDefaultLimit) with
  | some region, some after, some limit =>
    let region := region.toNat; let after := after.toNat; let limit := limit.toNat
    let restricted := who.role != .citizen
    if restricted && !who.inRegion region then failure 403 "region not authorized" else
    let head := st.db.lastSeq
    if after > head then failure 409 "resync" else
    let found := if restricted then st.db.syncAllRef region after (limit + 1)
                 else st.db.syncRef region 0 after (limit + 1)
    let page := found.take limit
    let events := page.map fun e =>
      let r := st.rows.getD e.seq default
      Json.arr #[toJson e.seq, toJson r.kind, .null, orNull r.incident, orNull r.category, orNull r.status,
                 orNull r.body, orNull r.lat, orNull r.lon, orNull r.at_]
    (200, Json.mkObj [("head", toJson head), ("generation", toJson (0 : Nat)), ("events", .arr events.toArray),
                      ("next", toJson ((page.getLast?.map (·.seq)).getD after)), ("more", .bool (found.length > limit))])
  | _, _, _ => failure 400 "invalid query"

def incident (st : State) (who : Actor) (id : String) : Reply :=
  match (within 1 largest (decimal id)).bind (fun i => (st.incidents[i.toNat]?).map (i.toNat, ·)) with
  | none => failure 404 "no such incident"
  | some (i, inc) =>
    let responder := who.role != .citizen && who.inRegion inc.region
    if !responder && inc.owner != who.sub then failure 404 "no such incident" else
    let summary := [("id", toJson i), ("region", toJson inc.region), ("category", toJson inc.category),
                    ("status", toJson inc.status), ("updated_seq", toJson inc.updated)]
    let report := if responder then
      let r := st.rows.getD i default
      [("report", Json.mkObj [("ts", .null), ("at", orNull r.at_), ("body", orNull r.body), ("lat", orNull r.lat), ("lon", orNull r.lon)])]
    else []
    (200, Json.mkObj (summary ++ report))

/-! ## One request -/

def actor (j : Json) : Except String Actor := do
  let sub ← j.getObjValAs? Nat "sub"
  let code ← j.getObjValAs? Nat "role"
  let some role := Role.all.find? (·.code == code) | throw "unknown role"
  let regions ← j.getObjValAs? (List Nat) "regions"
  return ⟨sub, role, regions⟩

def handle (st : State) (line : String) : Except String (State × Reply) := do
  let j ← Json.parse line
  let who ← actor (← j.getObjVal? "actor")
  match ← j.getObjValAs? String "op" with
  | "submit" =>
    let raw ← j.getObjValAs? String "raw"
    match decode who raw with
    | .error reply => return (st, reply)
    | .ok s => return submit st who s
  | "sync" => return (st, sync st who (← j.getObjVal? "query"))
  | "incident" => return (st, incident st who (← j.getObjValAs? String "id"))
  | other => throw s!"unknown operation {other}"

end Mina.Oracle
