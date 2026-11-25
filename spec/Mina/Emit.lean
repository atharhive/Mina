import Mina.Contract
import Mina.Codegen.Serialize
import Mina.Codegen.Responses
import Mina.Codegen.Routes
import Mina.Codegen.Schema
import Mina.Codegen.Domain

/-!
# Emitting the application layer

`app_gen.c` is produced from the contract (`Mina.Contract`). Fixed algorithmic skeletons are
templates; everything they are specialized by is computed here.

The runtime (`runtime/*.c`) is application independent: io_uring transport, HTTP framing,
JSON input scanning, HS256, output buffers and SQLite B-tree cursor primitives.
-/
namespace Mina.Emit
open Mina.Wire Mina.Codegen Mina.Contract

def templateMain : String := include_str "templates/app.c"

def appGen : String :=
  fill templateMain [
    ("HEADERS", emitHeaders dynamicStatuses),
    ("SCHEMA_CHECK", emitSchemaCheck Schema.tables Schema.indexes),
    ("ERRORS", emitErrors errors),
    ("KINDS", emitKinds endpoints),
    ("DECODE", emitDecode routes notFound),
    ("HEALTH_BODY", emitWhole healthShape),
    ("DEGRADED_BODY", emitWhole degradedShape),
    ("SESSION_BODY", emitWhole sessionShape),
    ("STORED_BODY", emitWhole storedShape),
    ("DUPLICATE_BODY", emitWhole duplicateShape),
    ("SESSION_SECONDS", toString sessionSeconds),
    ("HDR_OK", hdrIdent .ok),
    ("HDR_CREATED", hdrIdent .created),
    ("HDR_UNAVAILABLE", hdrIdent .unavailable)
  ]

def schemaSql : String := emitSchemaSql Schema.tables Schema.indexes

/-- The generated files, by name. -/
def outputs : List (String × String) := [("app_gen.c", appGen), ("domain.h", emitDomainHeader), ("schema.sql", schemaSql)]

end Mina.Emit
