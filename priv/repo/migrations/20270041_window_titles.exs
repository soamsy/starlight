defmodule StarlightBot.Repo.Migrations.WindowTitles do
  use Ecto.Migration

  def change do
    execute(
      "INSERT OR IGNORE INTO app_settings (key, value) VALUES ('window_titles', '[\"LimbusCompany\"]')",
      "DELETE FROM app_settings WHERE key = 'window_titles'"
    )
  end
end
