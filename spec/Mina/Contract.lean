import Mina.Wire

/-!
# The MINA API

Routes, error cases and JSON shapes, as data. The emitter turns them into C: route matching,
constant responses and serializers.
-/
namespace Mina.Contract
open Mina.Wire

def notFound : ErrorCase := ⟨"NOT_FOUND", .notFound, "not found"⟩

def errors : List ErrorCase := [notFound]

/-- Statuses of responses whose body is built at run time. -/
def dynamicStatuses : List Status := [.ok, .unavailable]

def healthShape : Shape := .obj [("status", .raw "\"ok\""), ("db", .raw "\"ok\""), ("uptime_s", .int "uptime")]
def degradedShape : Shape := .obj [("status", .raw "\"degraded\""), ("db", .raw "\"unreachable\""), ("error", .str "msg")]

def health : Endpoint := { kind := "K_HEALTH" }

def endpoints : List Endpoint := [health]

/-- `GET /v1/health` -/
def routes : List Route := [
  ⟨.get, [.lit "v1", .lit "health"], health⟩
]

end Mina.Contract
