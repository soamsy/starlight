defmodule StarlightBot.Repo.Migrations.TeamFreeSinners do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "teams" RENAME COLUMN "rest_bonus" TO "free_sinners"|
    execute ~S|UPDATE "teams" SET "free_sinners" = MIN(12, "free_sinners" / 5) WHERE "free_sinners" IS NOT NULL|
  end

  def down, do: :ok
end
