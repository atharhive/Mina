import Mina.Contract
import Mina.Codegen.Serialize
import Mina.Codegen.Responses
import Mina.Codegen.Routes
import Mina.Codegen.Schema
import Mina.Codegen.Domain
import Mina.Codegen.TypeScript
import Mina.Query

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
    ("EVENT_ORDINALS", emitOrdinals Schema.events),
    ("TABLE_EVENTS", cstr Schema.events.name),
    ("INDEX_REGION", cstr Schema.eventsByRegion.name),
    ("INDEX_REGION_KEYS", toString Schema.eventsByRegion.keys.length),
    ("SQL_HEADS", cstr Query.heads),
    ("SQL_BY_EID", cstr Query.byEid),
    ("SQL_EVENT_INSERT", cstr Query.eventInsert),
    ("SQL_INCIDENT_INSERT", cstr Query.incidentInsert),
    ("SQL_INCIDENT_STATE", cstr Query.incidentState),
    ("SQL_INCIDENT_UPDATE", cstr Query.incidentUpdate),
    ("SESSION_RATE", toString sessionLimit.rate),
    ("SESSION_BURST", toString sessionLimit.burst),
    ("CITIZEN_RATE", toString citizenLimit.rate),
    ("CITIZEN_BURST", toString citizenLimit.burst),
    ("CITIZEN_SLOTS", toString citizenSlots),
    ("SQL_INCIDENT", cstr Query.incident),
    ("SUMMARY_BODY", emitWhole summaryShape),
    ("REPORT_BODY", emitWhole reportShape),
    ("SQL_SYNC_PUBLIC", cstr Query.syncPublic),
    ("SQL_SYNC_ALL", cstr Query.syncAll),
    ("SQL_HEAD", cstr Query.head),
    ("SYNC_DEFAULT_LIMIT", toString syncDefaultLimit),
    ("SYNC_MAX_LIMIT", toString syncMaxLimit),
    ("EVENT_ROW", emitWhole eventShape),
    ("SYNC_BEFORE", (emitAround syncShape).1),
    ("SYNC_AFTER", (emitAround syncShape).2),
    ("STORED_BODY", emitWhole storedShape),
    ("DUPLICATE_BODY", emitWhole duplicateShape),
    ("SESSION_SECONDS", toString sessionSeconds),
    ("HDR_OK", hdrIdent .ok),
    ("HDR_CREATED", hdrIdent .created),
    ("HDR_UNAVAILABLE", hdrIdent .unavailable)
  ]

def schemaSql : String := emitSchemaSql Schema.tables Schema.indexes

def queriesSql : String :=
  "-- GENERATED from spec/Mina/Query.lean. Do not edit.\n" ++ String.join (Query.all.map (· ++ ";\n"))

/-- The generated files, by name. -/
def outputs : List (String × String) := [("app_gen.c", appGen), ("domain.h", emitDomainHeader), ("queries.sql", queriesSql),
   ("protocol.ts", emitProtocolTs),
   ("schema.sql", schemaSql)]

end Mina.Emit
