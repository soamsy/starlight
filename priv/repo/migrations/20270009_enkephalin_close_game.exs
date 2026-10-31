defmodule StarlightBot.Repo.Migrations.EnkephalinCloseGame do
  use Ecto.Migration

  def up do
    execute("INSERT OR IGNORE INTO app_settings (key, value) VALUES ('enkephalin_schedule_close_game', 'false')")
  end

  def down do
    execute("DELETE FROM app_settings WHERE key = 'enkephalin_schedule_close_game'")
  end
end
