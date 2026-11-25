/-!
# Domain vocabulary

The values the server, the operator tool and (later) the proofs share. The emitter writes them
to `domain.h`.
-/
namespace Mina.Domain

inductive Role where | citizen | responder | admin
  deriving Repr, DecidableEq

def Role.all : List Role := [.citizen, .responder, .admin]
def Role.code : Role → Nat | .citizen => 1 | .responder => 2 | .admin => 3
def Role.name : Role → String | .citizen => "citizen" | .responder => "responder" | .admin => "admin"

/-- Regions are numbered `1 .. maxRegion`. -/
def maxRegion : Nat := 1024

/-- Shortest accepted token key, in bytes. -/
def minSecretBytes : Nat := 32

end Mina.Domain
