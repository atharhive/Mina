import Mina.Domain
import Mina.Schema
import Mina.Contract
import Mina.Query

/-!
# The protocol for the web client

The same definitions the server's tables are generated from, as TypeScript, so a client cannot
disagree with the server about codes, field rules or limits.
-/
namespace Mina.Codegen
open Mina.Domain

private def quote (s : String) : String := "\"" ++ s ++ "\""
private def list (xs : List String) : String := "[" ++ ", ".intercalate xs ++ "]"

/-- `export const NAME = { key: code, ... } as const;` -/
def tsEnum {α : Type} (name : String) (all : List α) (key : α → String) (code : α → Nat) : String :=
  s!"export const {name} = \{\n" ++ String.join (all.map fun x => s!"  {key x}: {code x},\n") ++ "} as const;\n"

def categoryName : Category → String
  | .medical => "medical" | .rescue => "rescue" | .evacuation => "evacuation" | .food => "food" | .water => "water"

def safetyName : Safety → String | .safe => "safe" | .needsHelp => "needs_help"

def kindRule (k : Kind) : String :=
  let (lo, hi) := k.statusRange
  s!"  {k.code}: \{ roles: {list (k.roles.map (toString ·.code))}, " ++
  s!"required: {list (k.required.map (quote ·.name))}, optional: {list (k.optional.map (quote ·.name))}, " ++
  s!"statusRange: [{lo}, {hi}] },\n"

def emitProtocolTs : String :=
  "// GENERATED from spec/Mina (Mina.Codegen.TypeScript). Do not edit.\n\n" ++
  tsEnum "ROLE" Role.all Role.name Role.code ++
  tsEnum "KIND" Kind.all Kind.name Kind.code ++
  tsEnum "STATUS" Domain.Status.all Domain.Status.name Domain.Status.code ++
  tsEnum "CATEGORY" Category.all categoryName Category.code ++
  tsEnum "SAFETY" Safety.all safetyName Safety.code ++
  "\nexport type Field = " ++ " | ".intercalate (Field.all.map (quote ·.name)) ++ ";\n" ++
  "export interface KindRule { roles: readonly number[]; required: readonly Field[]; optional: readonly Field[]; statusRange: readonly [number, number] }\n" ++
  "export const KIND_RULES: Readonly<Record<number, KindRule>> = {\n" ++ String.join (Kind.all.map kindRule) ++ "};\n\n" ++
  "/** Every permitted change of an incident (Mina.Domain.transitions). */\n" ++
  "export const TRANSITIONS: ReadonlyArray<{ kind: number; source: number; target: number }> = [\n" ++
  String.join (transitions.map fun t =>
    s!"  \{ kind: {t.kind.code}, source: {t.source.code}, target: {t.target.code} },\n") ++
  "];\n\n" ++
  "/** A synchronised event is an array with these members, in this order. */\n" ++
  s!"export const EVENT_COLUMNS = {list ((Query.eventColumns.splitOn ", ").map quote)} as const;\n\n" ++
  "export const LIMITS = {\n" ++
  s!"  maxRegion: {maxRegion},\n  maxBodyChars: {Schema.maxBodyChars},\n  maxLatitude: {maxLatitude},\n" ++
  s!"  maxLongitude: {maxLongitude},\n  syncMaxLimit: {Contract.syncMaxLimit},\n" ++
  "} as const;\n"

end Mina.Codegen
