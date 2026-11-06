defmodule StarlightBot.Repo.Migrations.SinnerProfileBaseLocator do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "sinner_profiles" ADD COLUMN "base_locator_hook" TEXT|
  end

  def down, do: :ok
end
