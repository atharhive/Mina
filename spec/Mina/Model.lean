/-!
# The event store, as a model

The `events` table as ordinary Lean data: the list of its rows in rowid order, which is the
order SQLite's table B-tree holds them. The columns that decide what a read returns are kept;
the rest (kind, text, location, ...) travel with their row and do not affect any plan.

These definitions are what "correct" means: `syncRef` and `syncAllRef` say in Lean what the
reference SQL of `Mina.Query` says in SQL. Plans and theorems are stated against them.
-/
namespace Mina.Model

structure Event where
  seq : Nat
  eid : Nat
  region : Nat
  vis : Nat
  deriving Repr, DecidableEq, Inhabited

structure Db where
  events : List Event
  deriving Repr, Inhabited

/-- What the schema and the single writer guarantee: sequence numbers strictly increase in
storage order, every row is public (0) or restricted (1), and event ids are unique. -/
structure Inv (db : Db) : Prop where
  ordered : db.events.Pairwise (fun a b => a.seq < b.seq)
  visible : ∀ e ∈ db.events, e.vis = 0 ∨ e.vis = 1
  uniqueEid : db.events.Pairwise (fun a b => a.eid ≠ b.eid)

/-- `ORDER BY seq`. -/
def bySeq (a b : Event) : Bool := decide (a.seq ≤ b.seq)

/-- `WHERE region = r AND vis = v AND seq > after`. -/
def inStream (r v after : Nat) (e : Event) : Bool :=
  e.region == r && e.vis == v && decide (after < e.seq)

/-- `WHERE region = r AND seq > after`, either visibility. -/
def inRegion (r after : Nat) (e : Event) : Bool := e.region == r && decide (after < e.seq)

namespace Db

/-- `Mina.Query.syncPublic` for visibility `v`. -/
def syncRef (db : Db) (r v after n : Nat) : List Event :=
  ((db.events.filter (inStream r v after)).mergeSort bySeq).take n

/-- `Mina.Query.syncAll`. -/
def syncAllRef (db : Db) (r after n : Nat) : List Event :=
  ((db.events.filter (inRegion r after)).mergeSort bySeq).take n

/-- The row with a given sequence number (a table B-tree seek by rowid). -/
def row? (db : Db) (seq : Nat) : Option Event := db.events.find? (·.seq == seq)

/-- The newest sequence number, 0 for an empty store. -/
def lastSeq (db : Db) : Nat := (db.events.map (·.seq)).foldl max 0

/-- The insert of `Mina.Query`'s writer: `seq` is one more than the newest, and an event id
that is already stored changes nothing. -/
def submit (db : Db) (eid region vis : Nat) : Db :=
  if db.events.any (·.eid == eid) then db
  else ⟨db.events ++ [⟨db.lastSeq + 1, eid, region, vis⟩]⟩

end Db

/-! ## Facts about the model used by several proofs -/

theorem le_foldl_max : ∀ (l : List Nat) (a x : Nat), (x ≤ a ∨ x ∈ l) → x ≤ l.foldl max a
  | [], a, x, h => by simpa using h
  | y :: ys, a, x, h => by
    simp only [List.foldl_cons]
    apply le_foldl_max ys
    rcases h with h | h
    · exact Or.inl (by omega)
    · rcases List.mem_cons.mp h with rfl | h
      · exact Or.inl (by omega)
      · exact Or.inr h

theorem Db.seq_le_lastSeq (db : Db) (e : Event) (h : e ∈ db.events) : e.seq ≤ db.lastSeq :=
  le_foldl_max _ 0 _ (Or.inr (List.mem_map_of_mem h))

theorem sorted_bySeq {l : List Event} (h : l.Pairwise (fun a b => a.seq < b.seq)) :
    l.Pairwise (fun a b => bySeq a b = true) :=
  h.imp fun hab => by simp [bySeq]; omega

/-- In a store with strictly increasing sequence numbers, a row is determined by its number. -/
theorem eq_of_seq {l : List Event} (h : l.Pairwise (fun a b => a.seq < b.seq)) {a b : Event}
    (ha : a ∈ l) (hb : b ∈ l) (e : a.seq = b.seq) : a = b := by
  induction l with
  | nil => simp at ha
  | cons x xs ih =>
    obtain ⟨hx, hxs⟩ := List.pairwise_cons.mp h
    rcases List.mem_cons.mp ha with rfl | ha' <;> rcases List.mem_cons.mp hb with rfl | hb'
    · rfl
    · have := hx b hb'; omega
    · have := hx a ha'; omega
    · exact ih hxs ha' hb'

theorem Db.row?_of_mem (db : Db) (hi : Inv db) (e : Event) (h : e ∈ db.events) :
    db.row? e.seq = some e := by
  unfold Db.row?
  cases hf : db.events.find? (·.seq == e.seq) with
  | none =>
    have := List.find?_eq_none.mp hf e h
    simp at this
  | some x =>
    have hx : x ∈ db.events := List.mem_of_find?_eq_some hf
    have hs : x.seq = e.seq := by simpa using List.find?_some hf
    rw [eq_of_seq hi.ordered hx h hs]

/-- Under the invariant the references need no sort: storage order already is `ORDER BY seq`. -/
theorem Db.syncRef_eq_take (db : Db) (hi : Inv db) (r v after n : Nat) :
    db.syncRef r v after n = (db.events.filter (inStream r v after)).take n := by
  unfold Db.syncRef
  rw [List.mergeSort_of_pairwise (sorted_bySeq (hi.ordered.filter _))]

theorem Db.syncAllRef_eq_take (db : Db) (hi : Inv db) (r after n : Nat) :
    db.syncAllRef r after n = (db.events.filter (inRegion r after)).take n := by
  unfold Db.syncAllRef
  rw [List.mergeSort_of_pairwise (sorted_bySeq (hi.ordered.filter _))]

end Mina.Model
