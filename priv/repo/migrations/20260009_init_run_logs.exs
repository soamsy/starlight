defmodule StarlightBot.Repo.Migrations.InitRunLogs do
  use Ecto.Migration

  def change do
    create table(:run_logs) do
      add :team_id,          :integer
      add :team_name,        :string
      add :started_at,       :utc_datetime_usec
      add :ended_at,         :utc_datetime_usec
      add :result,           :string   # "success" | "failure" | "interrupted"
      add :floors_completed, :integer, default: 0
      add :duration_seconds, :integer
      add :notes,            :string
      timestamps()
    end

    create index(:run_logs, [:team_id])
    create index(:run_logs, [:started_at])
    create index(:run_logs, [:result])
  end
end
