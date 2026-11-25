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

def errors : List ErrorCase := [
  notFound, unavailable,
  ⟨"NO_BEARER", .unauthorized, "missing bearer token"⟩,
  ⟨"BAD_TOKEN", .unauthorized, "invalid token"⟩,
  ⟨"BAD_JSON", .badRequest, "invalid json"⟩,
  ⟨"BAD_EID", .badRequest, "invalid event id"⟩,
  ⟨"BAD_KIND", .badRequest, "invalid kind"⟩,
  ⟨"BAD_FIELDS", .badRequest, "missing or unexpected field"⟩,
  ⟨"BAD_REGION", .badRequest, "invalid region"⟩,
  ⟨"BAD_CATEGORY", .badRequest, "invalid category"⟩,
  ⟨"BAD_STATUS", .badRequest, "invalid status"⟩,
  ⟨"BAD_INCIDENT", .badRequest, "invalid incident"⟩,
  ⟨"BAD_LOCATION", .badRequest, "invalid location"⟩,
  ⟨"BAD_TIME", .badRequest, "invalid time"⟩,
  ⟨"BAD_BODY", .badRequest, "invalid body"⟩,
  ⟨"FORBIDDEN", .forbidden, "not permitted"⟩,
  ⟨"BAD_AREA", .forbidden, "region not authorized"⟩,
  ⟨"EID_USED", .conflict, "event id already used"⟩,
  ⟨"NO_INCIDENT", .notFound, "no such incident"⟩,
  ⟨"BAD_TRANSITION", .conflict, "invalid transition"⟩,
  ⟨"INTERNAL", .internal, "internal error"⟩]

/-- Statuses of responses whose body is built at run time. -/
def dynamicStatuses : List Status := [.ok, .created, .unavailable]

/-- The answer to an accepted submission, and to a retry of it. -/
def storedShape : Shape := .obj [("seq", .int "seq"), ("incident", .nint "incident" "incident")]
def duplicateShape : Shape := .obj [("seq", .int "seq"), ("incident", .nint "incident" "incident"), ("duplicate", .raw "true")]

def healthShape : Shape := .obj [("status", .raw "\"ok\""), ("db", .raw "\"ok\""), ("uptime_s", .int "uptime")]
def degradedShape : Shape := .obj [("status", .raw "\"degraded\""), ("db", .raw "\"unreachable\""), ("error", .str "msg")]

/-- The answer to `POST /v1/session`. -/
def sessionShape : Shape := .obj [("token", .str "token"), ("sub", .str "sub"), ("exp", .int "exp")]

/-- Lifetime of a citizen device token. -/
def sessionSeconds : Nat := 30 * 86400

def health : Endpoint := { kind := "K_HEALTH" }
/-- Answered while decoding: no database access. -/
def session : Endpoint := { kind := "K_SESSION" }

def event : Endpoint := { kind := "K_EVENT", isWrite := true }

def endpoints : List Endpoint := [health, session, event]

/-- `GET /v1/health`, `POST /v1/session`, `POST /v1/events` -/
def routes : List Route := [
  ⟨.get, [.lit "v1", .lit "health"], health, none⟩,
  ⟨.post, [.lit "v1", .lit "session"], session, some "issue_session"⟩,
  ⟨.post, [.lit "v1", .lit "events"], event, some "decode_event"⟩
]

end Mina.Contract
