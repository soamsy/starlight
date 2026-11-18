defmodule StarlightBot.BaseRepo.Migrations.SinnerProfileHdLocators do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "sinner_profiles" ADD COLUMN "hd_locator_hook" TEXT|
    execute ~S|ALTER TABLE "sinner_profiles" ADD COLUMN "hd_base_locator_hook" TEXT|
  end

  def down, do: :ok
end
