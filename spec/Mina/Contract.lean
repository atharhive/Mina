import Mina.Wire

/-!
# The MINA API

Routes, error cases and JSON shapes, as data. The emitter turns them into C: route matching,
constant responses and serializers.
-/
namespace Mina.Contract
open Mina.Wire

def notFound : ErrorCase := ⟨"NOT_FOUND", .notFound, "not found"⟩

def unavailable : ErrorCase := ⟨"UNAVAILABLE", .unavailable, "unavailable"⟩

def errors : List ErrorCase := [notFound, unavailable]

/-- Statuses of responses whose body is built at run time. -/
def dynamicStatuses : List Status := [.ok, .created, .unavailable]

def healthShape : Shape := .obj [("status", .raw "\"ok\""), ("db", .raw "\"ok\""), ("uptime_s", .int "uptime")]
def degradedShape : Shape := .obj [("status", .raw "\"degraded\""), ("db", .raw "\"unreachable\""), ("error", .str "msg")]

/-- The answer to `POST /v1/session`. -/
def sessionShape : Shape := .obj [("token", .str "token"), ("sub", .str "sub"), ("exp", .int "exp")]

/-- Lifetime of a citizen device token. -/
def sessionSeconds : Nat := 30 * 86400

def health : Endpoint := { kind := "K_HEALTH" }
/-- Answered while decoding: no database access. -/
def session : Endpoint := { kind := "K_SESSION" }

def endpoints : List Endpoint := [health, session]

/-- `GET /v1/health`, `POST /v1/session` -/
def routes : List Route := [
  ⟨.get, [.lit "v1", .lit "health"], health, none⟩,
  ⟨.post, [.lit "v1", .lit "session"], session, some "issue_session"⟩
]

end Mina.Contract
