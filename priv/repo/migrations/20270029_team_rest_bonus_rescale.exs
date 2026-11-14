defmodule StarlightBot.Repo.Migrations.TeamRestBonusRescale do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "teams" RENAME COLUMN "free_sinners" TO "rest_bonus"|
    execute ~S|UPDATE "teams" SET "rest_bonus" = "rest_bonus" * 5 WHERE "rest_bonus" IS NOT NULL|
  end

  def down, do: :ok
end
