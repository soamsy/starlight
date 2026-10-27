defmodule StarlightBot.Repo.Migrations.SchedulerLuxIncludesMirrorDungeon do
  use Ecto.Migration

  def up do
    execute """
    UPDATE runner_forms SET params = json_set(params, '$.then', 'mirror_dungeon')
    WHERE runner = 'luxcavation'
      AND EXISTS (SELECT 1 FROM scheduler_settings WHERE runner = 'luxcavation_then_mirror_dungeon')
    """

    execute "UPDATE scheduler_settings SET runner = 'luxcavation' WHERE runner = 'luxcavation_then_mirror_dungeon'"
  end

  def down do
    execute """
    UPDATE scheduler_settings SET runner = 'luxcavation_then_mirror_dungeon'
    WHERE runner = 'luxcavation'
      AND EXISTS (SELECT 1 FROM runner_forms WHERE runner = 'luxcavation' AND json_extract(params, '$.then') = 'mirror_dungeon')
    """
  end
end
