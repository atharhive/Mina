import Mina.Domain

/-!
# Properties of the incident life cycle

Facts about `Mina.Domain.transitions`, the list the C table `TRANSITIONS` is generated from.
The kernel checks each by evaluating every case.
-/
open Mina.Domain

/-- Nothing leaves `resolved`. -/
theorem resolved_is_final : ∀ t ∈ transitions, t.source ≠ .resolved ∧ t.source ≠ t.target := by decide

/-- Updates about an incident are public, and cannot carry a report's text or location. -/
theorem updates_are_public : ∀ t ∈ transitions,
    t.kind.restricted = false ∧ Field.body ∉ t.kind.required ++ t.kind.optional ∧
    Field.location ∉ t.kind.required ++ t.kind.optional ∧ Field.incident ∈ t.kind.required := by decide

/-- Citizens cannot change an incident. -/
theorem citizens_cannot_update : ∀ t ∈ transitions, Role.citizen ∉ t.kind.roles := by decide

/-- A kind either fixes the new status or takes it from the submitted `status`, whose accepted
range contains it. -/
theorem target_determined : ∀ t ∈ transitions,
    t.kind.fixedStatus = some t.target ∨
    (t.kind.fixedStatus = none ∧ Field.status ∈ t.kind.required ∧
     t.kind.statusRange.1 ≤ t.target.code ∧ t.target.code ≤ t.kind.statusRange.2) := by decide

/-- Every transition ends in a status the schema knows, never back at `open`. -/
theorem status_codes_valid : ∀ t ∈ transitions, t.target ∈ Status.all ∧ t.target ≠ .open_ := by decide
