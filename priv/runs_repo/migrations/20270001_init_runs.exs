defmodule StarlightBot.RunsRepo.Migrations.InitRuns do
  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE TABLE "run_logs" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "team_id" INTEGER, "team_name" TEXT, "started_at" TEXT, "ended_at" TEXT, "result" TEXT, "floors_completed" INTEGER DEFAULT 0, "duration_seconds" INTEGER, "notes" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """

    execute ~S"""
    CREATE INDEX "run_logs_team_id_index" ON "run_logs" ("team_id")
    """

    execute ~S"""
    CREATE INDEX "run_logs_started_at_index" ON "run_logs" ("started_at")
    """

    execute ~S"""
    CREATE INDEX "run_logs_result_index" ON "run_logs" ("result")
    """

    execute ~S"""
    CREATE TABLE "run_events" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "run_log_id" INTEGER CONSTRAINT "run_events_run_log_id_fkey" REFERENCES "run_logs"("id") ON DELETE CASCADE, "timestamp" TEXT NOT NULL, "event_type" TEXT NOT NULL, "screen" TEXT, "data" TEXT, "screenshot" BLOB, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """

    execute ~S"""
    CREATE INDEX "run_events_run_log_id_index" ON "run_events" ("run_log_id")
    """

    execute ~S"""
    CREATE INDEX "run_events_event_type_index" ON "run_events" ("event_type")
    """

    execute ~S"""
    CREATE INDEX "run_events_timestamp_index" ON "run_events" ("timestamp")
    """
  end

  def down, do: :ok
end
