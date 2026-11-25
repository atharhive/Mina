import Mina.Domain

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

def emitDomainHeader : String :=
  "/* GENERATED from spec/Mina/Domain.lean. Do not edit. */\n" ++
  "#ifndef MINA_DOMAIN_H\n#define MINA_DOMAIN_H\n\n" ++
  emitDefines (enumDefines "ROLE" Role.all Role.name Role.code ++
    [("MAX_REGION", maxRegion), ("MIN_SECRET_BYTES", minSecretBytes)]) ++
  "\n#endif\n"

end Mina.Codegen
