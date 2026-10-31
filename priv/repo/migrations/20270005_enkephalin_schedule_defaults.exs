defmodule StarlightBot.Repo.Migrations.EnkephalinScheduleDefaults do
  use Ecto.Migration

  def up do
    execute("""
    INSERT OR IGNORE INTO app_settings (key, value) VALUES
      ('enkephalin_schedule_enabled', 'false'),
      ('enkephalin_schedule_window_start', '08:00'),
      ('enkephalin_schedule_window_end', '22:00'),
      ('enkephalin_schedule_interval_minutes', '180'),
      ('enkephalin_schedule_launch_mode', 'none'),
      ('enkephalin_schedule_steam_app_id', '1973530'),
      ('enkephalin_schedule_exe_path', ''),
      ('enkephalin_schedule_launch_timeout_s', '300')
    """)
  end

  def down do
    execute("DELETE FROM app_settings WHERE key LIKE 'enkephalin_schedule_%'")
  end
end
