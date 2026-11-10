defmodule StarlightBot.BaseRepo.Migrations.SinnerProfileDefenseAffinity do
  use Ecto.Migration

  def up do
    execute ~S|ALTER TABLE "sinner_profiles" ADD COLUMN "defense_affinity" TEXT|
  end

  def down, do: :ok
end
