defmodule StarlightBot.Repo.Migrations.InitRunEvents do
  use Ecto.Migration

  def change do
    create table(:run_events) do
      add :run_log_id,  references(:run_logs, on_delete: :delete_all)
      add :timestamp,   :utc_datetime_usec, null: false
      add :event_type,  :string, null: false
      add :screen,      :string
      add :data,        :string  # JSON payload
      add :screenshot,  :binary  # optional JPEG crop
      timestamps()
    end

    create index(:run_events, [:run_log_id])
    create index(:run_events, [:event_type])
    create index(:run_events, [:timestamp])
  end
end
