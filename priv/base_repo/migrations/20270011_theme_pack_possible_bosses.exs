defmodule StarlightBot.BaseRepo.Migrations.ThemePackPossibleBosses do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "theme_packs" ADD COLUMN "possible_bosses" TEXT|
  end

  def down, do: :ok
end
