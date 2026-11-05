defmodule StarlightBot.BaseRepo.Migrations.TeamTemplates do
  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE TABLE "team_templates" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "name" TEXT NOT NULL,
      "hooks" TEXT DEFAULT '[]' NOT NULL,
      "gift_plan" TEXT,
      "battle_plan" TEXT,
      "pack_plan" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """

    execute ~S|CREATE UNIQUE INDEX "team_templates_name_index" ON "team_templates" ("name")|
  end

  def down, do: :ok
end
