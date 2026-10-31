defmodule StarlightBot.RunsRepo.Migrations.DailyProgressSource do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "daily_progress" ADD COLUMN "source" TEXT DEFAULT 'manual' NOT NULL|
  end

  def down, do: :ok
end
