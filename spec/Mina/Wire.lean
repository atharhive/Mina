/-!
# Wire vocabulary

The application-independent language a contract is written in: statuses, error cases, JSON
shapes and routes. `Mina.Contract` states MINA's API with it; `Mina.Codegen` turns it into C.
-/
namespace Mina.Wire

inductive Status where
  | ok | created | badRequest | unauthorized | forbidden | notFound | conflict | internal | unavailable
  deriving Repr, DecidableEq, Inhabited

def Status.line : Status → String
  | .ok => "200 OK"
  | .created => "201 Created"
  | .badRequest => "400 Bad Request"
  | .unauthorized => "401 Unauthorized"
  | .forbidden => "403 Forbidden"
  | .notFound => "404 Not Found"
  | .conflict => "409 Conflict"
  | .internal => "500 Internal Server Error"
  | .unavailable => "503 Service Unavailable"

def Status.code : Status → Nat
  | .ok => 200 | .created => 201 | .badRequest => 400 | .unauthorized => 401 | .forbidden => 403
  | .notFound => 404 | .conflict => 409 | .internal => 500 | .unavailable => 503

/-- Status line and headers, up to and including `Content-Length: `. -/
def headerPrefix (s : Status) : String :=
  "HTTP/1.1 " ++ s.line ++ "\r\nContent-Type: application/json\r\nContent-Length: "

/-! ## JSON

`jsonString` renders a string value the way the runtime serializer does: `"` and `\` are
escaped, control characters use the short escapes or `\u00XX`, and everything else
(including non-ASCII) is copied. -/

def hexDigit (n : Nat) : Char := "0123456789abcdef".toList.getD n '0'

def escapeChar (c : Char) : String :=
  if c = '"' then "\\\""
  else if c = '\\' then "\\\\"
  else if c = '\x08' then "\\b"
  else if c = '\x0c' then "\\f"
  else if c = '\n' then "\\n"
  else if c = '\r' then "\\r"
  else if c = '\t' then "\\t"
  else if c.toNat < 0x20 then "\\u00" ++ String.singleton (hexDigit (c.toNat / 16)) ++ String.singleton (hexDigit (c.toNat % 16))
  else String.singleton c

def jsonString (s : String) : String := "\"" ++ String.join (s.toList.map escapeChar) ++ "\""

/-- A JSON value whose shape is fixed and whose leaves are filled at run time. -/
inductive Shape where
  | obj (fields : List (String × Shape))
  | int (var : String)          -- a C `i64` expression
  | str (var : String)          -- a C byte string `var` with length `var_len`
  | bool (var : String)         -- a C truth value
  | nint (var present : String) -- `var`, or `null` when the C condition `present` is false
  | raw (json : String)         -- constant JSON text
  | embed (part : String)       -- JSON written by the code that uses the shape
  deriving Repr, Inhabited

/-! ## Errors -/

structure ErrorCase where
  name : String          -- C identifier suffix
  status : Status
  message : String
  deriving Repr

def errorBody (e : ErrorCase) : String := "{\"error\":" ++ jsonString e.message ++ "}"

/-- A complete constant response. -/
def errorResponse (e : ErrorCase) : String :=
  let body := errorBody e
  headerPrefix e.status ++ toString body.utf8ByteSize ++ "\r\n\r\n" ++ body

/-! ## Routes -/

inductive Method where | get | post
  deriving Repr, DecidableEq

inductive Seg where
  | lit (s : String)
  | id                            -- a path parameter
  deriving Repr, DecidableEq

/-- A job kind of the generated application. -/
structure Endpoint where
  kind : String                   -- C enumerator
  isWrite : Bool := false
  deriving Repr, DecidableEq

structure Route where
  method : Method
  path : List Seg
  endpoint : Endpoint
  /-- A C function `int f(const req_t *rq, job_t *j)` of the template. It runs after the route
  matched; returning 0 means it has already decided the response. -/
  decoder : Option String := none
  deriving Repr

end Mina.Wire
