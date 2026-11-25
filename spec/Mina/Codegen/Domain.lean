import Mina.Domain
import Mina.Schema

/-!
# Domain constants as C
-/
namespace Mina.Codegen
open Mina.Domain

def emitDefines (defs : List (String × Nat)) : String :=
  String.join (defs.map fun (n, v) => s!"#define {n} {v}\n")

/-- `#define PREFIX_NAME code` for every value of an enumeration. -/
def enumDefines {α : Type} (pre : String) (all : List α) (name : α → String) (code : α → Nat) :
    List (String × Nat) :=
  all.map fun x => (pre ++ "_" ++ (name x).toUpper, code x)

def bitmask (bits : List Nat) : Nat := bits.foldl (fun m b => m ||| (1 <<< b)) 0

def fieldBit (f : Field) : Nat := Field.all.idxOf f

/-- `KIND_SPECS[code]`; a code that names no kind has no permitted role. -/
def emitKindSpecs : String :=
  let size := (Kind.all.map Kind.code).foldl Nat.max 0 + 1
  let row (k : Kind) : String :=
    let (lo, hi) := k.statusRange
    s!"  [{k.code}] = \{.roles = {bitmask (k.roles.map Role.code)}, " ++
    s!".restricted = {if k.restricted then 1 else 0}, .need = {bitmask (k.required.map fieldBit)}, " ++
    s!".allow = {bitmask ((k.required ++ k.optional).map fieldBit)}, .status_lo = {lo}, .status_hi = {hi}, " ++
    s!".target = {(k.fixedStatus.map (·.code)).getD 0}},  /* {k.name} */"
  "typedef struct { u8 roles, restricted, need, allow, status_lo, status_hi, target; } kind_spec;\n" ++
  s!"#define KIND_COUNT {size}\n" ++
  "static const kind_spec KIND_SPECS[KIND_COUNT] = {\n" ++ "\n".intercalate (Kind.all.map row) ++ "\n};\n"

/-- `TRANSITIONS[kind][source]`: the set of permitted target statuses, one bit per code. -/
def emitTransitions : String :=
  let size := (Domain.Status.all.map Domain.Status.code).foldl Nat.max 0 + 1
  let row (k : Kind) : Option String :=
    let cells := Domain.Status.all.filterMap fun s =>
      let ts := (transitions.filter fun t => t.kind == k && t.source == s).map (·.target.code)
      if ts.isEmpty then none else some s!"[{s.code}] = {bitmask ts}"
    if cells.isEmpty then none
    else some s!"  [{k.code}] = \{{", ".intercalate cells}},  /* {k.name} */"
  s!"static const u8 TRANSITIONS[KIND_COUNT][{size}] = \{\n" ++
  "\n".intercalate (Kind.all.filterMap row) ++ "\n};\n"

def emitDomainHeader : String :=
  "/* GENERATED from spec/Mina/Domain.lean. Do not edit. */\n" ++
  "#ifndef MINA_DOMAIN_H\n#define MINA_DOMAIN_H\n\n" ++
  emitDefines (enumDefines "ROLE" Role.all Role.name Role.code ++
    enumDefines "KIND" Kind.all Kind.name Kind.code ++
    enumDefines "STATUS" Domain.Status.all Domain.Status.name Domain.Status.code ++
    Field.all.map (fun f => ("F_" ++ f.name.toUpper, 1 <<< fieldBit f)) ++
    [("CATEGORY_MAX", (Category.all.map Category.code).foldl Nat.max 0),
     ("MAX_REGION", maxRegion), ("MAX_LAT", maxLatitude), ("MAX_LON", maxLongitude), ("MAX_TIME", maxTime),
     ("MAX_BODY_CHARS", Schema.maxBodyChars), ("MIN_SECRET_BYTES", minSecretBytes)]) ++
  "\n" ++ emitKindSpecs ++ emitTransitions ++ "\n#endif\n"

end Mina.Codegen
