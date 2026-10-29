defmodule StarlightBot.Repo.Migrations.PerTeamPlans do
  use Ecto.Migration

  @plans [gift_plan_id: "gift_plans", battle_plan_id: "battle_plans", pack_plan_id: "pack_plans"]

  def up do
    for {column, table} <- @plans do
      %{rows: rows} = repo().query!("SELECT id, name, #{column} FROM teams WHERE #{column} IS NOT NULL ORDER BY position, id")

      rows
      |> Enum.group_by(fn [_id, _name, plan_id] -> plan_id end)
      |> Enum.each(fn {plan_id, [_keeper | extras]} ->
        Enum.each(extras, fn [team_id, team_name, _] -> copy_plan(table, column, plan_id, team_id, team_name) end)
      end)
    end
  end

  def down, do: :ok

  defp copy_plan(table, column, plan_id, team_id, team_name) do
    %{rows: [[copy_id]]} =
      repo().query!(
        "INSERT INTO #{table} (name, data, inserted_at, updated_at) SELECT ?, data, inserted_at, updated_at FROM #{table} WHERE id = ? RETURNING id",
        [unique_name(table, team_name), plan_id]
      )

    repo().query!("UPDATE teams SET #{column} = ? WHERE id = ?", [copy_id, team_id])
  end

  defp unique_name(table, base) do
    Stream.concat([base], Stream.iterate(2, &(&1 + 1)) |> Stream.map(&"#{base} #{&1}"))
    |> Enum.find(fn name -> repo().query!("SELECT 1 FROM #{table} WHERE name = ?", [name]).rows == [] end)
  end
end
