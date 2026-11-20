defmodule Mix.Tasks.Db.Backup do
  @shortdoc "Copy the writable databases into the backups folder"
  @moduledoc """
  Runs an integrity check on the base and user databases, then writes a consistent
  copy of each into `backups/` next to the runs database. For each database the
  newest 3 copies are kept, plus the newest copy from each of the 7 most recent
  days that have one. A database that fails its check is not backed up and the
  task fails.

      mix db.backup
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    results = StarlightBot.DbSafety.backup()

    for {name, result} <- results do
      case result do
        {:ok, dest} -> Mix.shell().info("db.backup: #{name} -> #{dest}")
        :recent -> Mix.shell().info("db.backup: #{name} already backed up this second")
        {:error, messages} -> Mix.shell().error("db.backup: #{name} failed: #{Enum.join(messages, "; ")}")
      end
    end

    if Enum.any?(results, &match?({_, {:error, _}}, &1)), do: Mix.raise("db.backup: refusing to continue with a damaged database")
  end
end
