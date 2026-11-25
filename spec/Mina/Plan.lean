import Mina.Model

/-!
# Read plans for synchronisation

What the generated C does instead of running SQL, written over the model with the B-tree
primitives it uses:

| primitive (model) | generated C |
|---|---|
| `Db.index` | the index B-tree `events_region_vis`: entries `(region, vis, rowid)` in order |
| `dropWhile` before the start key | one index seek to `(region, vis, after + 1)` |
| `takeWhile` on the prefix | stepping the index cursor while region and visibility match |
| `Db.row?` | a table B-tree seek by rowid |
| `List.merge` | two cursors, the smaller rowid taken first |

`syncPlan_eq` and `syncAllPlan_eq` say these plans return exactly what the reference queries
return. Neither sorts, and neither runs SQLite's bytecode interpreter.

Assumed, not proved: that SQLite's index B-tree yields its entries in key order and that a
seek by rowid yields the row stored under it.
-/
namespace Mina.Model

structure Key where
  region : Nat
  vis : Nat
  seq : Nat
  deriving Repr, DecidableEq, Inhabited

def Event.key (e : Event) : Key := ⟨e.region, e.vis, e.seq⟩

/-- The order of index entries: region, then visibility, then rowid. -/
def Key.le (a b : Key) : Bool :=
  decide (a.region < b.region ∨ (a.region = b.region ∧ (a.vis < b.vis ∨ (a.vis = b.vis ∧ a.seq ≤ b.seq))))

theorem Key.le_iff (a b : Key) : Key.le a b = true ↔
    a.region < b.region ∨ (a.region = b.region ∧ (a.vis < b.vis ∨ (a.vis = b.vis ∧ a.seq ≤ b.seq))) := by
  simp [Key.le]

theorem Key.le_trans (a b c : Key) : Key.le a b = true → Key.le b c = true → Key.le a c = true := by
  simp only [Key.le_iff]; omega

theorem Key.le_total (a b : Key) : (Key.le a b || Key.le b a) = true := by
  simp only [Bool.or_eq_true, Key.le_iff]; omega

theorem Key.le_antisymm (a b : Key) (h : Key.le a b = true) (h' : Key.le b a = true) : a = b := by
  simp only [Key.le_iff] at h h'
  cases a; cases b
  simp only [Key.mk.injEq] at *
  omega

namespace Db

def index (db : Db) : List Key := (db.events.map Event.key).mergeSort Key.le

end Db

/-- Seek to the first entry at or after `(r, v, after + 1)`, then walk while the prefix holds. -/
def scanKeys (idx : List Key) (r v after : Nat) : List Key :=
  (idx.dropWhile fun k => !Key.le ⟨r, v, after + 1⟩ k).takeWhile fun k => k.region == r && k.vis == v

namespace Db

def syncPlan (db : Db) (r v after n : Nat) : List Event :=
  ((scanKeys db.index r v after).take n).filterMap fun k => db.row? k.seq

def syncAllPlan (db : Db) (r after n : Nat) : List Event :=
  (List.merge (db.syncPlan r 0 after n) (db.syncPlan r 1 after n) bySeq).take n

end Db

/-! ## Walking a sorted list -/

theorem dropWhile_eq_filter {α} (p : α → Bool) :
    ∀ (l : List α), l.Pairwise (fun a b => p a = true → p b = true) → l.dropWhile (fun a => !p a) = l.filter p
  | [], _ => rfl
  | x :: xs, h => by
    obtain ⟨hx, hxs⟩ := List.pairwise_cons.mp h
    cases hp : p x with
    | true =>
      have all : ∀ y ∈ x :: xs, p y = true := by
        intro y hy
        rcases List.mem_cons.mp hy with rfl | hy
        · exact hp
        · exact hx y hy hp
      rw [List.filter_eq_self.mpr all]
      simp [hp]
    | false =>
      simp only [List.dropWhile_cons, List.filter_cons, hp, Bool.not_false, ite_true]
      exact dropWhile_eq_filter p xs hxs

theorem takeWhile_eq_filter {α} (q : α → Bool) :
    ∀ (l : List α), l.Pairwise (fun a b => q b = true → q a = true) → l.takeWhile q = l.filter q
  | [], _ => rfl
  | x :: xs, h => by
    obtain ⟨hx, hxs⟩ := List.pairwise_cons.mp h
    cases hq : q x with
    | true =>
      simp only [List.takeWhile_cons, List.filter_cons, hq, ite_true]
      rw [takeWhile_eq_filter q xs hxs]
    | false =>
      have none : xs.filter q = [] := by
        apply List.filter_eq_nil_iff.mpr
        intro y hy hqy
        have := hx y hy hqy
        simp [hq] at this
      simp [hq, none]

/-- On a sorted index, the seek and walk select exactly the stream's entries. -/
theorem scanKeys_eq (idx : List Key) (h : idx.Pairwise (fun a b => Key.le a b = true)) (r v after : Nat) :
    scanKeys idx r v after = idx.filter fun k => k.region == r && k.vis == v && decide (after < k.seq) := by
  unfold scanKeys
  rw [dropWhile_eq_filter (fun k => Key.le ⟨r, v, after + 1⟩ k) idx
      (h.imp fun {a b} hab ha => Key.le_trans _ _ _ ha hab)]
  rw [takeWhile_eq_filter]
  · rw [List.filter_filter]
    apply List.filter_congr
    intro k _
    rw [Bool.eq_iff_iff]
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq, Key.le_iff]
    omega
  · refine (h.filter _).imp_of_mem fun {a b} ha hb hab hq => ?_
    have sa := (List.mem_filter.mp ha).2
    simp only [Bool.and_eq_true, beq_iff_eq, Key.le_iff] at sa hab hq ⊢
    omega

/-! ## The plans -/

theorem filterMap_row (db : Db) (hi : Inv db) :
    ∀ (l : List Event), (∀ e ∈ l, e ∈ db.events) → (l.map Event.key).filterMap (fun k => db.row? k.seq) = l
  | [], _ => rfl
  | x :: xs, h => by
    have hx : db.row? x.key.seq = some x := db.row?_of_mem hi x (h x List.mem_cons_self)
    simp only [List.map_cons, List.filterMap_cons, hx]
    rw [filterMap_row db hi xs fun e he => h e (List.mem_cons_of_mem _ he)]

/-- The stream's index entries are the keys of the stream's rows, in the same order. -/
theorem index_filter (db : Db) (hi : Inv db) (r v after : Nat) :
    (db.index.filter fun k => k.region == r && k.vis == v && decide (after < k.seq))
      = (db.events.filter (inStream r v after)).map Event.key := by
  apply List.Perm.eq_of_pairwise (le := fun a b => Key.le a b = true)
  · intro a b _ _ h h'
    exact Key.le_antisymm a b h h'
  · exact (List.pairwise_mergeSort Key.le_trans Key.le_total _).filter _
  · rw [List.pairwise_map]
    refine (hi.ordered.filter _).imp_of_mem fun {a b} ha hb hab => ?_
    have sa := (List.mem_filter.mp ha).2
    have sb := (List.mem_filter.mp hb).2
    simp only [inStream, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at sa sb
    simp only [Event.key, Key.le_iff]
    omega
  · refine ((List.mergeSort_perm _ _).filter _).trans ?_
    rw [List.filter_map]
    exact .of_eq rfl

end Mina.Model

open Mina.Model

/-- **The native scan of a stream is the reference query.** -/
theorem syncPlan_eq (db : Db) (hi : Inv db) (r v after n : Nat) :
    db.syncPlan r v after n = db.syncRef r v after n := by
  unfold Db.syncPlan
  rw [scanKeys_eq db.index (List.pairwise_mergeSort Key.le_trans Key.le_total _),
    index_filter db hi, db.syncRef_eq_take hi, ← List.map_take]
  exact filterMap_row db hi _ fun e he => (List.mem_filter.mp (List.mem_of_mem_take he)).1

namespace Mina.Model

/-- Merging the first `n` of two lists and keeping `n` is the same as merging them whole. -/
theorem take_merge {α} (le : α → α → Bool) :
    ∀ (n : Nat) (xs ys : List α), (List.merge xs ys le).take n = (List.merge (xs.take n) (ys.take n) le).take n
  | 0, _, _ => by simp
  | n + 1, [], ys => by simp [List.take_take]
  | n + 1, x :: xs, [] => by simp [List.take_take]
  | n + 1, x :: xs, y :: ys => by
    simp only [List.take_succ_cons, List.cons_merge_cons]
    split
    · simp only [List.take_succ_cons, List.cons.injEq, true_and]
      rw [take_merge le n xs (y :: ys), take_merge le n (xs.take n) (y :: ys.take n)]
      congr 2
      · simp [List.take_take]
      · cases n with
        | zero => simp
        | succ m => simp [List.take_take, Nat.min_eq_left (Nat.le_succ m)]
    · simp only [List.take_succ_cons, List.cons.injEq, true_and]
      rw [take_merge le n (x :: xs) ys, take_merge le n (x :: xs.take n) (ys.take n)]
      congr 2
      · cases n with
        | zero => simp
        | succ m => simp [List.take_take, Nat.min_eq_left (Nat.le_succ m)]
      · simp [List.take_take]

/-- With only two visibilities, merging the two streams of a region gives the region. -/
theorem merge_streams (db : Db) (hi : Inv db) (r after : Nat) :
    List.merge (db.events.filter (inStream r 0 after)) (db.events.filter (inStream r 1 after)) bySeq
      = db.events.filter (inRegion r after) := by
  have split : ∀ v, db.events.filter (inStream r v after)
      = (db.events.filter (inRegion r after)).filter (fun e => e.vis == v) := by
    intro v
    rw [List.filter_filter]
    apply List.filter_congr
    intro e _
    rw [Bool.eq_iff_iff]
    simp only [inStream, inRegion, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq]
    omega
  have other : (db.events.filter (inRegion r after)).filter (fun e => e.vis == 1)
      = (db.events.filter (inRegion r after)).filter (fun e => !(e.vis == 0)) := by
    apply List.filter_congr
    intro e he
    have := hi.visible e (List.mem_filter.mp he).1
    rcases this with h | h <;> simp [h]
  apply List.Perm.eq_of_pairwise (le := fun a b => bySeq a b = true)
  · intro a b ha hb hab hba
    have mem : ∀ x, x ∈ List.merge (db.events.filter (inStream r 0 after)) (db.events.filter (inStream r 1 after)) bySeq →
        x ∈ db.events := by
      intro x hx
      rcases List.mem_merge.mp hx with h | h <;> exact (List.mem_filter.mp h).1
    simp only [bySeq, decide_eq_true_eq] at hab hba
    exact eq_of_seq hi.ordered (mem a ha) (List.mem_filter.mp hb).1 (by omega)
  · exact List.pairwise_merge (fun a b c h h' => by simp only [bySeq, decide_eq_true_eq] at *; omega)
      (fun a b => by simp only [bySeq, Bool.or_eq_true, decide_eq_true_eq]; omega) _ _
      (sorted_bySeq (hi.ordered.filter _)) (sorted_bySeq (hi.ordered.filter _))
  · exact sorted_bySeq (hi.ordered.filter _)
  · refine List.Perm.trans (List.merge_perm_append bySeq) ?_
    rw [split 0, split 1, other]
    exact List.filter_append_perm _ _

end Mina.Model

/-- **The responder's two-cursor merge is the reference query.** -/
theorem syncAllPlan_eq (db : Db) (hi : Inv db) (r after n : Nat) :
    db.syncAllPlan r after n = db.syncAllRef r after n := by
  unfold Db.syncAllPlan
  rw [syncPlan_eq db hi, syncPlan_eq db hi, db.syncRef_eq_take hi, db.syncRef_eq_take hi,
    ← take_merge, merge_streams db hi, db.syncAllRef_eq_take hi]
