defmodule StarlightBot.BaseRepo.Migrations.EgoGiftDifficultyFlags do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "ego_gifts" ADD COLUMN "hard_only" INTEGER NOT NULL DEFAULT 0|
    execute ~S|ALTER TABLE "ego_gifts" ADD COLUMN "extreme_only" INTEGER NOT NULL DEFAULT 0|
  end

  def down, do: :ok
end
