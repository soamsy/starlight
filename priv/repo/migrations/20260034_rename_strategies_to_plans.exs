defmodule StarlightBot.Repo.Migrations.RenameStrategiesToPlans do
  use Ecto.Migration

  @tables [gift_strategies: :gift_plans, battle_strategies: :battle_plans, theme_pack_plans: :pack_plans]
  @team_columns [gift_strategy_id: :gift_plan_id, battle_strategy_id: :battle_plan_id, theme_pack_plan_id: :pack_plan_id]

  def up do
    for {from, to} <- @tables, do: rename_plan_table(from, to)
    for {from, to} <- @team_columns, do: rename(table(:teams), from, to: to)
  end

  def down do
    for {from, to} <- @tables, do: rename_plan_table(to, from)
    for {from, to} <- @team_columns, do: rename(table(:teams), to, to: from)
  end

  defp rename_plan_table(from, to) do
    drop unique_index(from, [:name])
    rename table(from), to: table(to)
    create unique_index(to, [:name])
  end
end
