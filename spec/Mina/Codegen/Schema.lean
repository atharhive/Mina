import Mina.Schema
import Mina.Codegen.C

/-!
# Schema SQL and the startup layout check
-/
namespace Mina.Codegen
open Mina.Schema

def columnSql (c : Column) : String :=
  let key := if c.rowid then " PRIMARY KEY" else ""
  let con := if c.constraint.isEmpty then "" else " " ++ c.constraint
  s!"  {c.name} {c.ty.sql}{key}{con}"

def tableSql (t : Table) : String :=
  s!"CREATE TABLE {t.name} (\n" ++ ",\n".intercalate (t.cols.map columnSql) ++ "\n);\n"

def indexSql (i : Index) : String :=
  s!"CREATE INDEX {i.name} ON {i.table} ({", ".intercalate i.keys});\n"

def emitSchemaSql (ts : List Table) (is : List Index) : String :=
  "-- GENERATED from spec/Mina/Schema.lean. Do not edit.\n" ++
  String.join (ts.map tableSql) ++ String.join (is.map indexSql)

/-- The form `table_layout` compares against `PRAGMA table_info`. -/
def layout (t : Table) : String :=
  ",".intercalate (t.cols.map fun c => s!"{c.name}:{c.ty.sql}:{if c.rowid then 1 else 0}")

def emitSchemaCheck (ts : List Table) (is : List Index) : String :=
  let checks :=
    ts.map (fun t => s!"table_layout({cstr t.name}, {cstr (layout t)})") ++
    is.map (fun i => s!"index_layout({cstr i.name}, {cstr (",".intercalate i.keys)})")
  "static int schema_check(void) {\n  return " ++ " &&\n         ".intercalate checks ++ ";\n}\n"

end Mina.Codegen
