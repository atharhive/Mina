import Mina.Wire
import Mina.Codegen.C

/-!
# Serializers from JSON shapes

All constant bytes of a shape are merged into single literals, and the buffer room a response
needs is computed here.
-/
namespace Mina.Codegen
open Mina.Wire

inductive Piece where
  | lit (s : String) | int (v : String) | nint (v p : String) | nstr (v p : String) | str (v : String) | bool (v : String) | embed (p : String)
  deriving Repr, Inhabited

partial def pieces : Shape → List Piece
  | .obj fs =>
    let inner := fs.zipIdx.flatMap fun ((k, v), i) =>
      (if i == 0 then [] else [Piece.lit ","]) ++ [Piece.lit (jsonString k ++ ":")] ++ pieces v
    [Piece.lit "{"] ++ inner ++ [Piece.lit "}"]
  | .int v => [.int v]
  | .str v => [.str v]
  | .bool v => [.bool v]
  | .nint v p => [.nint v p]
  | .nstr v p => [.nstr v p]
  | .arr items =>
    let inner := items.zipIdx.flatMap fun (v, i) => (if i == 0 then [] else [Piece.lit ","]) ++ pieces v
    [Piece.lit "["] ++ inner ++ [Piece.lit "]"]
  | .raw j => [.lit j]
  | .embed p => [.embed p]

/-- Adjacent constant pieces become one literal. -/
def merge (ps : List Piece) : List Piece :=
  (ps.foldl (fun acc p => match acc, p with
    | .lit a :: rest, .lit b => .lit (a ++ b) :: rest
    | _, _ => p :: acc) []).reverse

def outLit (s : String) : String := s!"out_lit(o, {cstr s}, {bytes s});"

def emitPiece : Piece → String
  | .lit s => outLit s
  | .int v => s!"out_i64(o, {v});"
  | .str v => s!"out_jstr(o, {v}, {v}_len);"
  | .bool v => s!"if ({v}) " ++ outLit "true" ++ " else " ++ outLit "false"
  | .nint v p => s!"if ({p}) out_i64(o, {v}); else " ++ outLit "null"
  | .nstr v p => s!"if ({p}) out_jstr(o, {v}, {v}_len); else " ++ outLit "null"
  | .embed _ => ""

/-- Upper bound on the bytes a list of pieces writes. -/
def room (ps : List Piece) : String :=
  let fixed := ps.foldl (fun n p => match p with
    | .lit s => n + bytes s | .int _ => n + 20 | .nint _ _ => n + 20 | .bool _ => n + 5 | _ => n) 0
  let strs := ps.filterMap fun p => match p with
    | .str v | .nstr v _ => some s!"JSTR_ROOM({v}_len)" | _ => none
  " + ".intercalate (toString fixed :: strs)

/-- Code for the pieces of a shape before and after its embedded part. -/
def emitAround (s : Shape) : String × String :=
  let ps := merge (pieces s)
  let before := ps.takeWhile (fun p => !(p matches .embed _))
  let after := (ps.dropWhile (fun p => !(p matches .embed _))).drop 1
  let code (xs : List Piece) := s!"out_need(o, {room xs});\n  " ++ "\n  ".intercalate (xs.map emitPiece)
  (code before, code after)

def emitWhole (s : Shape) : String := (emitAround s).1

end Mina.Codegen
