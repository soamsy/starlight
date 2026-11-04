defmodule StarlightBot.Repo.Migrations.PlansBelongToTeams do
  use Ecto.Migration

  @tables [{:gift_plans, "gift_plan_id"}, {:battle_plans, "battle_plan_id"}, {:pack_plans, "pack_plan_id"}]

  def up do
    for {table, field} <- @tables do
      alter table(table) do
        add :team_id, :integer
      end

      create index(table, [:team_id])
      execute("UPDATE #{table} SET team_id = (SELECT teams.id FROM teams WHERE teams.#{field} = #{table}.id)")
    end
  end

  def down do
    for {table, _field} <- @tables do
      drop index(table, [:team_id])

      alter table(table) do
        remove :team_id
      end
    end
  end
end
