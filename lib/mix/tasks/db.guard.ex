defmodule Mix.Tasks.Db.Guard do
  @shortdoc "Fail if another process has the databases open"
  @moduledoc """
  Fails when a running server (or anything else) holds the Starlight databases open.
  `mix db.migrate` and `mix db.checkpoint` run this first, because touching a SQLite
  file from a second process while the server has it open can corrupt it.

      mix db.guard
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    case StarlightBot.DbSafety.holders() do
      [] ->
        :ok

      holders ->
        lines = Enum.map_join(holders, "\n", fn {pid, command} -> "  #{pid}  #{command}" end)
        Mix.raise("The databases are open in another process. Stop it first:\n#{lines}")
    end
  end
end
