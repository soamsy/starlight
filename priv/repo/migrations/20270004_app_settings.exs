defmodule StarlightBot.Repo.Migrations.AppSettings do
  use Ecto.Migration

  def change do
    create table(:app_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string, null: false
    end

    execute(
      """
      INSERT INTO app_settings (key, value)
      SELECT 'enkephalin_convert_count',
             COALESCE((SELECT json_extract(params, '$.enkephalin_convert_count') FROM runner_forms WHERE runner = 'mirror_dungeon'),
                      (SELECT json_extract(params, '$.enkephalin_convert_count') FROM runner_forms WHERE runner = 'luxcavation'),
                      '0')
      """,
      "DELETE FROM app_settings"
    )
  end
end
