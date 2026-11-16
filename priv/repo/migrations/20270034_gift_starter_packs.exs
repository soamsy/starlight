defmodule StarlightBot.Repo.Migrations.GiftStarterPacks do
  use Ecto.Migration

  def up do
    execute ~S"""
    CREATE TABLE "gift_starter_packs" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "name" TEXT NOT NULL,
      "affinity" TEXT NOT NULL DEFAULT 'any',
      "data" TEXT NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """

    execute ~S|CREATE UNIQUE INDEX "gift_starter_packs_name_index" ON "gift_starter_packs" ("name")|
  end

  def down, do: :ok
end
