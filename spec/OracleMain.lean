import Mina.Oracle

/-- Reads one request per line and writes the expected answer, until the input ends. -/
partial def serve (input output : IO.FS.Stream) (st : Mina.Oracle.State) : IO UInt32 := do
  let line ← input.getLine
  if line.isEmpty then return 0
  match Mina.Oracle.handle st line with
  | .error e =>
    IO.eprintln s!"oracle: {e}"
    return 1
  | .ok (st, status, body) =>
    output.putStrLn (Lean.Json.mkObj [("status", Lean.toJson status), ("body", body)]).compress
    output.flush
    serve input output st

def main : IO UInt32 := do
  serve (← IO.getStdin) (← IO.getStdout) {}
