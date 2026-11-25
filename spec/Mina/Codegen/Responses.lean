import Mina.Wire
import Mina.Codegen.C

/-!
# Constant responses and header prefixes

Every error response is emitted as complete constant bytes, with its `Content-Length`
computed here.
-/
namespace Mina.Codegen
open Mina.Wire

def errIdent (e : ErrorCase) : String := "E_" ++ e.name

def emitErrors (errors : List ErrorCase) : String :=
  "\n".intercalate (errors.map fun e =>
    let r := errorResponse e
    s!"static const u8 {errIdent e}[] = {cstr r};  /* {e.status.code} {e.message} */") ++
  "\n#define ERR(name) obuf_static(E_##name, sizeof E_##name - 1)\n"

def hdrIdent (s : Status) : String := s!"HDR_{s.code}"

def emitHeaders (statuses : List Status) : String :=
  "\n".intercalate (statuses.map fun s =>
    s!"static const u8 {hdrIdent s}[] = {cstr (headerPrefix s)};") ++ "\n"

end Mina.Codegen
