defmodule StarlightBot.BaseRepo.Migrations.Teams do
  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE TABLE "teams" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "name" TEXT NOT NULL,
      "notes" TEXT,
      "gift_template_id" INTEGER,
      "battle_template_id" INTEGER,
      "pack_template_id" INTEGER,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """

    execute ~S|CREATE UNIQUE INDEX "teams_name_index" ON "teams" ("name")|
  end

  def down, do: :ok
end
