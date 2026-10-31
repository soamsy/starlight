defmodule StarlightBot.RunsRepo.Migrations.DailyProgress do
  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE TABLE "daily_progress" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "kind" TEXT NOT NULL, "amount" INTEGER NOT NULL, "completed_at" TEXT NOT NULL)
    """

    execute ~S"""
    CREATE INDEX "daily_progress_completed_at_index" ON "daily_progress" ("completed_at")
    """
  end

  def down, do: :ok
end
