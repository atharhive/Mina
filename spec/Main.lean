import Mina.Emit

/-- `lake exe derive <dir>`: write the generated application layer and schema to `<dir>`. -/
def main (args : List String) : IO UInt32 := do
  let dir := args.headD "gen"
  IO.FS.createDirAll dir
  for (name, text) in Mina.Emit.outputs do
    IO.FS.writeFile (dir ++ "/" ++ name) text
    IO.println s!"wrote {dir}/{name}"
  return 0
