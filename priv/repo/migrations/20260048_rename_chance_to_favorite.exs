defmodule StarlightBot.Repo.Migrations.RenameChanceToFavorite do
  use Ecto.Migration

  def up do
    execute ~s|UPDATE pack_plans SET data = REPLACE(data, '"chance":', '"favorite":') WHERE data LIKE '%"chance":%'|
  end

  def down do
    execute ~s|UPDATE pack_plans SET data = REPLACE(data, '"favorite":', '"chance":') WHERE data LIKE '%"favorite":%'|
  end
end
