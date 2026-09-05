defmodule Mix.Tasks.Twilic.EmitRustClientFixtures do
  @shortdoc "Emit interop fixture frames for Rust client check"
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    IO.write(Twilic.InteropFixtures.emit_interop_fixtures())
  end
end
