#!/usr/bin/env bash
# The theorems the server relies on: each must exist, be checked by the Lean kernel, and depend
# on no axiom beyond Lean's standard three. Needs ./build.sh to have run (it builds spec/).
set -uo pipefail
cd "$(dirname "$0")/../spec"
LAKE="${LAKE:-$(command -v lake || echo "$HOME/.elan/bin/lake")}"
THEOREMS="syncPlan_eq syncAllPlan_eq head_empty head_empty_all head_preserved inv_empty inv_submit apply_idem
          cursor_mono pages_compose no_skip resolved_is_final updates_are_public citizens_cannot_update
          target_determined status_codes_valid"
fail=0
if grep -rnE '\bsorry\b|^[[:space:]]*axiom |native_decide' Mina Mina.lean; then echo "  FAIL escape hatch in the specification"; fail=1
else echo "  ok   no sorry, axiom or native_decide"; fi
"$LAKE" build Mina >/dev/null || { echo "  FAIL the specification does not build"; exit 1; }
probe="$(mktemp --suffix=.lean)"; trap 'rm -f "$probe"' EXIT
{ echo 'import Mina'; for t in $THEOREMS; do echo "open Mina.Model Mina.Domain in #print axioms $t"; done; } >"$probe"
out="$("$LAKE" env lean "$probe" 2>&1)"
for t in $THEOREMS; do
  line="$(tr '\n' ' ' <<<"$out" | grep -oE "'[A-Za-z0-9_.]*\\b$t' (does not depend on any axioms|depends on axioms: \[[^]]*\])" | head -1)"
  rest="$(sed -E 's/.*depends on axioms: \[//; s/\]$//' <<<"$line" | tr -d ' ' | tr ',' '\n' | grep -vxE 'propext|Classical.choice|Quot.sound')"
  if [ -z "$line" ]; then echo "  FAIL $t: not found"; fail=1
  elif [[ "$line" == *"depends on axioms"* && -n "$rest" ]]; then echo "  FAIL $t uses: $rest"; fail=1
  else echo "  ok   $t"; fi
done
[ $fail = 0 ] && echo "proofs: ok" || { echo "proofs: FAILED"; exit 1; }
