defmodule StarlightBot.RunsRepo.Migrations.RuntimeState do
  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE TABLE "runtime_state" ("key" TEXT PRIMARY KEY, "value" TEXT NOT NULL)
    """
  end

  def down, do: :ok
end
