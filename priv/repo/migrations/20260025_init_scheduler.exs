defmodule StarlightBot.Repo.Migrations.InitScheduler do
  use Ecto.Migration

  def up do
    create table(:scheduler_settings, primary_key: false) do
      add :id, :integer, primary_key: true
      add :enabled, :boolean, null: false, default: false
      add :runner, :string, null: false, default: "mirror_dungeon"
      add :window_start, :string, null: false, default: "09:00"
      add :window_end, :string, null: false, default: "12:00"
      add :mirror_dungeon_action, :text
      add :luxcavation_action, :text
      add :launch_mode, :string, null: false, default: "steam"
      add :steam_app_id, :string, null: false, default: "1973530"
      add :exe_path, :string
      add :launch_timeout_s, :integer, null: false, default: 600
      add :last_fired_on, :string
      add :updated_at, :utc_datetime, null: false
    end

    flush()

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    repo().query!("INSERT INTO scheduler_settings (id, updated_at) VALUES (1, ?)", [now])
  end

  def down do
    drop table(:scheduler_settings)
  end
end
