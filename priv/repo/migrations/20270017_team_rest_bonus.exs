defmodule StarlightBot.Repo.Migrations.TeamRestBonus do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "teams" ADD COLUMN "rest_bonus" INTEGER|
  end

  def down, do: :ok
end
