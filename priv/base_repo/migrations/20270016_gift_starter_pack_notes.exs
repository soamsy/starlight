defmodule StarlightBot.BaseRepo.Migrations.GiftStarterPackNotes do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "gift_starter_packs" ADD COLUMN "notes" TEXT|
  end

  def down, do: :ok
end
