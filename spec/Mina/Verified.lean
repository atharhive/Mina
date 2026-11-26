import Mina.Sync
import Mina.Transition

/-!
# The theorems a viewer is told about

The Observatory lists these. Each name is written with a double backtick, so the build fails if
it does not name an existing declaration. They are theorems about the model (`docs/PROOFS.md`).
-/
namespace Mina.Verified

def theorems : List (Lean.Name × String) := [
  (``syncPlan_eq, "The native index scan returns exactly what the reference query returns."),
  (``syncAllPlan_eq, "Merging the two streams of a region returns exactly the responder query."),
  (``head_empty, "A cursor at or past a stream's newest event has an empty answer."),
  (``head_preserved, "Updating the remembered newest number at each insert keeps it exact."),
  (``apply_idem, "Submitting an event twice is submitting it once."),
  (``cursor_mono, "A synchronisation cursor never goes back."),
  (``pages_compose, "Two pages read in turn equal one longer page."),
  (``no_skip, "No event up to the returned cursor is missed, even as events are appended."),
  (``resolved_is_final, "A resolved incident cannot change again."),
  (``updates_are_public, "Public incident updates cannot carry a report's text or location."),
  (``citizens_cannot_update, "Citizens cannot change an incident's status.")]

end Mina.Verified
