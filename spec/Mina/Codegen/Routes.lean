import Mina.Wire
import Mina.Codegen.C

/-!
# Route matching

`app_decode` is a chain of constant-prefix comparisons, one block per route, in contract order.
-/
namespace Mina.Codegen
open Mina.Wire

def methodC : Method → String
  | .get => "M_GET"
  | .post => "M_POST"

def emitSeg : Seg → String
  | .lit s => let t := "/" ++ s; s!"path_lit(&s, e, {cstr t}, {bytes t})"
  | .id => "path_param(&s, e, &id_p, &id_n)"

def emitRoute (r : Route) : String :=
  let cond := " && ".intercalate (r.path.map emitSeg ++ ["s == e"])
  let decode := match r.decoder with
    | some f =>
      let params := if r.path.contains .id then ", id_p, id_n" else ""
      s!"      if (!{f}(rq, j{params})) return;\n"
    | none => ""
  s!"  if (rq->method == {methodC r.method}) \{
    const u8 *s = p, *e = p + n, *id_p = 0; u32 id_n = 0;
    (void)id_p; (void)id_n;
    if ({cond}) \{
{decode}      j->kind = {r.endpoint.kind}; j->is_write = {if r.endpoint.isWrite then 1 else 0};
      return;
    }
  }"

def emitDecode (routes : List Route) (fallback : ErrorCase) : String :=
  "static void app_decode(const req_t *rq, job_t *j) {\n  const u8 *p = rq->path;\n  u32 n = rq->path_len;\n" ++
  "\n".intercalate (routes.map emitRoute) ++ s!"\n  j->resp = ERR({fallback.name});\n}\n"

def emitKinds (endpoints : List Endpoint) : String :=
  "enum { " ++ ", ".intercalate ("K_NONE = 0" :: endpoints.map (·.kind)) ++ " };"

end Mina.Codegen
