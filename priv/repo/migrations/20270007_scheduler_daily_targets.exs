defmodule StarlightBot.Repo.Migrations.SchedulerDailyTargets do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "scheduler_settings" ADD COLUMN "exp_waves" INTEGER DEFAULT 0 NOT NULL|
    execute ~S|ALTER TABLE "scheduler_settings" ADD COLUMN "thread_waves" INTEGER DEFAULT 0 NOT NULL|
    execute ~S|ALTER TABLE "scheduler_settings" ADD COLUMN "md_runs" INTEGER DEFAULT 0 NOT NULL|
    execute ~S|ALTER TABLE "scheduler_settings" DROP COLUMN "runner"|
    execute ~S|ALTER TABLE "scheduler_settings" DROP COLUMN "last_fired_on"|
  end

  def down, do: :ok
end
