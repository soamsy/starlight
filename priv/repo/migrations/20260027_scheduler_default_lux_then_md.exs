defmodule StarlightBot.Repo.Migrations.SchedulerDefaultLuxThenMd do
  use Ecto.Migration

  def up do
    execute "UPDATE scheduler_settings SET runner = 'luxcavation_then_mirror_dungeon' WHERE runner = 'mirror_dungeon'"
  end

  def down do
    execute "UPDATE scheduler_settings SET runner = 'mirror_dungeon' WHERE runner = 'luxcavation_then_mirror_dungeon'"
  end
end
