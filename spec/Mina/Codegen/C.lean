/-!
# C text helpers
-/
namespace Mina.Codegen

def octal (b : Nat) : String :=
  "\\" ++ toString (b / 64) ++ toString (b / 8 % 8) ++ toString (b % 8)

/-- A C string literal with exactly these bytes (UTF-8). -/
def cstr (s : String) : String := Id.run do
  let mut out := "\""
  let mut prevOctal := false
  for b in s.toUTF8.toList do
    let n := b.toNat
    let isDigit := n ≥ 48 && n ≤ 57
    let piece :=
      if n == 34 then "\\\""
      else if n == 92 then "\\\\"
      else if n == 13 then "\\r"
      else if n == 10 then "\\n"
      else if n == 63 then "\\?"
      else if n < 32 || n ≥ 127 then octal n
      else if prevOctal && isDigit then "\"\"" ++ String.singleton (Char.ofNat n)
      else String.singleton (Char.ofNat n)
    prevOctal := n < 32 || n ≥ 127
    out := out ++ piece
  return out ++ "\""

def bytes (s : String) : Nat := s.utf8ByteSize

/-- Fill `@{key}` placeholders. -/
def fill (tpl : String) (kvs : List (String × String)) : String :=
  kvs.foldl (fun acc (k, v) => acc.replace ("@{" ++ k ++ "}") v) tpl

end Mina.Codegen
