defmodule StarlightBot.Repo.Migrations.SchedulerCloseGame do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "scheduler_settings" ADD COLUMN "close_game_when_done" INTEGER DEFAULT 0 NOT NULL|
  end

  def down, do: :ok
end
