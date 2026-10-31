defmodule StarlightBot.Repo.Migrations.LuxcavationFormWaves do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE runner_forms
    SET params = json_remove(
      json_set(
        params,
        '$.exp_waves', CAST(CAST(json_extract(params, '$.exp_consecutive') AS INTEGER) * CAST(json_extract(params, '$.exp_repeats') AS INTEGER) AS TEXT),
        '$.thread_waves', CAST(CAST(json_extract(params, '$.thread_consecutive') AS INTEGER) * CAST(json_extract(params, '$.thread_repeats') AS INTEGER) AS TEXT)
      ),
      '$.exp_consecutive', '$.exp_repeats', '$.thread_consecutive', '$.thread_repeats'
    )
    WHERE runner = 'luxcavation'
      AND json_extract(params, '$.exp_consecutive') IS NOT NULL
      AND json_extract(params, '$.thread_consecutive') IS NOT NULL
    """)
  end

  def down, do: :ok
end
