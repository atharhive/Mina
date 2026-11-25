/-!
# Domain vocabulary

The values the server, the operator tool and (later) the proofs share. The emitter writes them
to `domain.h`.
-/
namespace Mina.Domain

inductive Role where | citizen | responder | admin
  deriving Repr, DecidableEq

def Role.all : List Role := [.citizen, .responder, .admin]
def Role.code : Role → Nat | .citizen => 1 | .responder => 2 | .admin => 3
def Role.name : Role → String | .citizen => "citizen" | .responder => "responder" | .admin => "admin"

inductive Category where | medical | rescue | evacuation | food | water
  deriving Repr, DecidableEq

def Category.all : List Category := [.medical, .rescue, .evacuation, .food, .water]
def Category.code : Category → Nat
  | .medical => 1 | .rescue => 2 | .evacuation => 3 | .food => 4 | .water => 5

/-- What a person reports about their own safety. -/
inductive Safety where | safe | needsHelp
  deriving Repr, DecidableEq

def Safety.all : List Safety := [.safe, .needsHelp]
def Safety.code : Safety → Nat | .safe => 1 | .needsHelp => 2

inductive Status where | open_ | acknowledged | inProgress | resolved
  deriving Repr, DecidableEq

def Status.all : List Status := [.open_, .acknowledged, .inProgress, .resolved]
def Status.code : Status → Nat | .open_ => 1 | .acknowledged => 2 | .inProgress => 3 | .resolved => 4
def Status.name : Status → String
  | .open_ => "open" | .acknowledged => "acknowledged" | .inProgress => "in_progress" | .resolved => "resolved"

/-! ## Event kinds

Each kind states who may submit it, who may read it, and which fields a submission carries. The
server's validation table is generated from these definitions. -/

inductive Field where | region | category | status | body | location | incident | at_
  deriving Repr, DecidableEq

def Field.all : List Field := [.region, .category, .status, .body, .location, .incident, .at_]
def Field.name : Field → String
  | .region => "region" | .category => "category" | .status => "status" | .body => "body"
  | .location => "location" | .incident => "incident" | .at_ => "at"

inductive Kind where | sosCreated | safetyReported | alertPublished
  deriving Repr, DecidableEq

def Kind.all : List Kind := [.sosCreated, .safetyReported, .alertPublished]
def Kind.code : Kind → Nat | .sosCreated => 1 | .safetyReported => 5 | .alertPublished => 6
def Kind.name : Kind → String
  | .sosCreated => "sos_created" | .safetyReported => "safety_reported" | .alertPublished => "alert_published"

def Kind.roles : Kind → List Role
  | .sosCreated | .safetyReported => [.citizen, .responder, .admin]
  | .alertPublished => [.responder, .admin]

/-- Responder-only events are not part of the public stream. -/
def Kind.restricted : Kind → Bool
  | .sosCreated | .safetyReported => true
  | .alertPublished => false

def Kind.required : Kind → List Field
  | .sosCreated => [.region, .category]
  | .safetyReported => [.region, .status]
  | .alertPublished => [.region, .body]

def Kind.optional : Kind → List Field
  | .sosCreated | .safetyReported => [.body, .location, .at_]
  | .alertPublished => [.at_]

/-- The accepted values of the `status` field, as an inclusive range of codes. -/
def Kind.statusRange : Kind → Nat × Nat
  | .safetyReported => (Safety.safe.code, Safety.needsHelp.code)
  | _ => (0, 0)

/-- Regions are numbered `1 .. maxRegion`. -/
def maxRegion : Nat := 1024

/-- Coordinates are degrees times 100,000, about one metre. -/
def maxLatitude : Nat := 90 * 100000
def maxLongitude : Nat := 180 * 100000

/-- Latest accepted device creation time, in Unix seconds. -/
def maxTime : Nat := 99999999999

/-- Shortest accepted token key, in bytes. -/
def minSecretBytes : Nat := 32

end Mina.Domain
