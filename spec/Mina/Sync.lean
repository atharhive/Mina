import Mina.Plan

/-!
# Skipping reads, retries and cursors

* **Empty synchronisation.** The server may remember, per region and visibility, the newest
  sequence number (`headOf`). A client whose cursor has reached it gets an empty answer without
  any B-tree access (`head_empty`), and the remembered value is kept exact by updating it at
  each insert (`head_preserved`). This is derived state, not a cache of answers.
* **Retries.** Submitting an event id again changes nothing (`apply_idem`).
* **Cursors.** A cursor never goes back (`cursor_mono`), pages join into one ordered result
  (`pages_compose`), and nothing at or below a returned cursor is missed, even when events are
  appended later (`no_skip`). This relies on the single writer: events become visible in
  sequence order.
-/
namespace Mina.Model

namespace Db

/-- The newest sequence number of a stream, 0 if it is empty. -/
def headOf (db : Db) (r v : Nat) : Nat :=
  ((db.events.filter fun e => e.region == r && e.vis == v).map (·.seq)).foldl max 0

def add (db : Db) (e : Event) : Db := ⟨db.events ++ [e]⟩

end Db

/-- The remembered heads agree with the store. -/
def HeadInv (h : Nat → Nat → Nat) (db : Db) : Prop := ∀ r v, h r v = db.headOf r v

/-- The update the server makes after inserting `e`. -/
def bump (h : Nat → Nat → Nat) (e : Event) : Nat → Nat → Nat :=
  fun r v => if e.region = r ∧ e.vis = v then max (h r v) e.seq else h r v

/-- The cursor a client sends next: the last event it received, or the one it had. -/
def nextCursor (page : List Event) (after : Nat) : Nat := (page.getLast?.map (·.seq)).getD after

theorem seq_le_headOf (db : Db) (r v : Nat) (e : Event) (h : e ∈ db.events) (hr : e.region = r) (hv : e.vis = v) :
    e.seq ≤ db.headOf r v := by
  apply le_foldl_max
  exact Or.inr (List.mem_map_of_mem (List.mem_filter.mpr ⟨h, by simp [hr, hv]⟩))

end Mina.Model

open Mina.Model

/-- **A cursor at or past a stream's head has nothing to read.** -/
theorem head_empty (db : Db) (r v after n : Nat) (h : db.headOf r v ≤ after) :
    db.syncRef r v after n = [] := by
  have none : db.events.filter (inStream r v after) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro e he hs
    simp only [inStream, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hs
    have := seq_le_headOf db r v e he hs.1.1 hs.1.2
    omega
  simp [Db.syncRef, none]

/-- The same for a responder: past both heads, the region has nothing to read. -/
theorem head_empty_all (db : Db) (hi : Inv db) (r after n : Nat) (h0 : db.headOf r 0 ≤ after) (h1 : db.headOf r 1 ≤ after) :
    db.syncAllRef r after n = [] := by
  have none : db.events.filter (inRegion r after) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro e he hs
    simp only [inRegion, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hs
    rcases hi.visible e he with hv | hv
    · have := seq_le_headOf db r 0 e he hs.1 hv; omega
    · have := seq_le_headOf db r 1 e he hs.1 hv; omega
  simp [Db.syncAllRef, none]

/-- **Updating the head at each insert keeps it exact.** -/
theorem head_preserved (h : Nat → Nat → Nat) (db : Db) (e : Event) (hh : HeadInv h db) :
    HeadInv (bump h e) (db.add e) := by
  intro r v
  unfold bump Db.headOf Db.add
  simp only [List.filter_append, List.map_append, List.foldl_append]
  by_cases m : e.region = r ∧ e.vis = v
  · rw [ite_eq_left m, hh r v]
    simp [Db.headOf, m.1, m.2]
  · rw [ite_eq_right m, hh r v]
    have : (e.region == r && e.vis == v) = false := by
      rw [Bool.eq_false_iff]; simpa using m
    simp [Db.headOf, this]

/-- The invariant holds for an empty store, so by `inv_submit` for every store the server can
build. -/
theorem inv_empty : Inv ⟨[]⟩ := ⟨List.Pairwise.nil, by simp, List.Pairwise.nil⟩

/-- An insert through `submit` keeps the invariant. -/
theorem inv_submit (db : Db) (hi : Inv db) (eid region vis : Nat) (hv : vis = 0 ∨ vis = 1) :
    Inv (db.submit eid region vis) := by
  unfold Db.submit
  split
  · exact hi
  · rename_i fresh
    refine ⟨?_, ?_, ?_⟩
    · exact List.pairwise_append.mpr ⟨hi.ordered, List.pairwise_singleton _ _, fun a ha b hb => by
        simp only [List.mem_singleton] at hb; subst hb
        have := db.seq_le_lastSeq a ha
        show a.seq < db.lastSeq + 1
        omega⟩
    · intro e he
      rcases List.mem_append.mp he with he | he
      · exact hi.visible e he
      · simp only [List.mem_singleton] at he; subst he; exact hv
    · exact List.pairwise_append.mpr ⟨hi.uniqueEid, List.pairwise_singleton _ _, fun a ha b hb => by
        simp only [List.mem_singleton] at hb; subst hb
        intro same
        apply fresh
        exact List.any_eq_true.mpr ⟨a, ha, by simp [same]⟩⟩

/-- **Submitting the same event id twice is submitting it once**, whatever the retry carries. -/
theorem apply_idem (db : Db) (eid region vis region' vis' : Nat) :
    (db.submit eid region vis).submit eid region' vis' = db.submit eid region vis := by
  have stored : (db.submit eid region vis).events.any (·.eid == eid) = true := by
    unfold Db.submit
    split
    · assumption
    · simp
  generalize db.submit eid region vis = d at stored ⊢
  unfold Db.submit
  rw [ite_eq_left stored]

/-- **A cursor never goes back.** -/
theorem cursor_mono (db : Db) (r v after n : Nat) :
    after ≤ nextCursor (db.syncRef r v after n) after := by
  unfold nextCursor
  cases h : (db.syncRef r v after n).getLast? with
  | none => simp
  | some k =>
    have hk : k ∈ db.syncRef r v after n := List.mem_of_getLast? h
    have := (List.mem_filter.mp (List.mem_mergeSort.mp (List.mem_of_mem_take hk))).2
    simp only [inStream, Bool.and_eq_true, decide_eq_true_eq] at this
    simp only [Option.map_some, Option.getD_some]
    omega

namespace Mina.Model

/-- In an ordered list, the elements after the last of the first `n` are exactly the rest. -/
theorem filter_after_last (l : List Event) (h : l.Pairwise (fun a b => a.seq < b.seq)) (n : Nat) (k : Event)
    (hk : (l.take n).getLast? = some k) : l.filter (fun e => decide (k.seq < e.seq)) = l.drop n := by
  have split : (l.take n ++ l.drop n).Pairwise (fun a b => a.seq < b.seq) := by
    rw [List.take_append_drop]; exact h
  obtain ⟨front, _, cross⟩ := List.pairwise_append.mp split
  obtain ⟨init, hinit⟩ := List.getLast?_eq_some_iff.mp hk
  have taken : (l.take n).filter (fun e => decide (k.seq < e.seq)) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro e he
    rw [hinit] at he front
    simp only [decide_eq_true_eq]
    rcases List.mem_append.mp he with he | he
    · have := (List.pairwise_append.mp front).2.2 e he k (List.mem_singleton.mpr rfl); omega
    · simp only [List.mem_singleton] at he; subst he; omega
  have dropped : (l.drop n).filter (fun e => decide (k.seq < e.seq)) = l.drop n := by
    apply List.filter_eq_self.mpr
    intro e he
    simp only [decide_eq_true_eq]
    exact cross k (List.mem_of_getLast? hk) e he
  conv => lhs; rw [← List.take_append_drop n l]
  rw [List.filter_append, taken, dropped, List.nil_append]

end Mina.Model

/-- **Two pages are one longer page**: reading `n` and then `m` from the returned cursor gives
the same events as reading `n + m` at once. -/
theorem pages_compose (db : Db) (hi : Inv db) (r v after n m : Nat) :
    db.syncRef r v after (n + m)
      = db.syncRef r v after n ++ db.syncRef r v (nextCursor (db.syncRef r v after n) after) m := by
  have mono := cursor_mono db r v after n
  simp only [db.syncRef_eq_take hi] at mono ⊢
  rw [List.take_add]
  congr 1
  unfold nextCursor at mono ⊢
  cases hk : ((db.events.filter (inStream r v after)).take n).getLast? with
  | none =>
    simp only [Option.map_none, Option.getD_none]
    rcases List.take_eq_nil_iff.mp (List.getLast?_eq_none_iff.mp hk) with h | h
    · subst h; simp
    · simp [h]
  | some k =>
    rw [hk] at mono
    simp only [Option.map_some, Option.getD_some] at mono ⊢
    congr 1
    rw [← filter_after_last _ (hi.ordered.filter _) n k hk, List.filter_filter]
    apply List.filter_congr
    intro e _
    rw [Bool.eq_iff_iff]
    simp only [inStream, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq]
    omega

/-- **Nothing is skipped**: every event of the stream between the old cursor and the new one is
in the page, also when more events have been appended since the page was read. -/
theorem no_skip (db : Db) (later : List Event) (hi : Inv ⟨db.events ++ later⟩) (r v after n : Nat)
    (e : Event) (he : e ∈ db.events ++ later) (hs : inStream r v after e = true)
    (hc : e.seq ≤ nextCursor (db.syncRef r v after n) after) : e ∈ db.syncRef r v after n := by
  obtain ⟨old, _, cross⟩ := List.pairwise_append.mp hi.ordered
  have hdb : Inv db := ⟨old, fun x hx => hi.visible x (List.mem_append_left _ hx),
    (List.pairwise_append.mp hi.uniqueEid).1⟩
  have gt : after < e.seq := by
    simp only [inStream, Bool.and_eq_true, decide_eq_true_eq] at hs; omega
  rw [db.syncRef_eq_take hdb] at hc ⊢
  unfold nextCursor at hc
  cases hk : ((db.events.filter (inStream r v after)).take n).getLast? with
  | none => rw [hk] at hc; simp at hc; omega
  | some k =>
    rw [hk] at hc
    simp only [Option.map_some, Option.getD_some] at hc
    have kmem : k ∈ db.events := (List.mem_filter.mp (List.mem_of_mem_take (List.mem_of_getLast? hk))).1
    have emem : e ∈ db.events := by
      rcases List.mem_append.mp he with h | h
      · exact h
      · have := cross k kmem e h; omega
    have all : e ∈ db.events.filter (inStream r v after) := List.mem_filter.mpr ⟨emem, hs⟩
    rw [← List.take_append_drop n (db.events.filter (inStream r v after))] at all
    rcases List.mem_append.mp all with h | h
    · exact h
    · rw [← filter_after_last _ (old.filter _) n k hk] at h
      have := (List.mem_filter.mp h).2
      simp only [decide_eq_true_eq] at this
      omega
