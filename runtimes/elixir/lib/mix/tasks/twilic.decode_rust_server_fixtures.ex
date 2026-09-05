defmodule Mix.Tasks.Twilic.DecodeRustServerFixtures do
  @shortdoc "Decode Rust server interop fixture frames from stdin"
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    input = IO.binread(:stdio, :eof)

    Twilic.InteropFixtures.decode_rust_server_frames(input)
  end
end
