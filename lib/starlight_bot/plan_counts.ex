defmodule StarlightBot.PlanCounts do
  alias StarlightBot.{Plans, Teams}

  @topic "plan_counts"
  @fields [battle_plans: :battle_plan_id, pack_plans: :pack_plan_id, gift_plans: :gift_plan_id]

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def broadcast(team_id, table, data) when is_integer(team_id) do
    Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, {:plan_count, team_id, table, count(table, data)})
  end

  def broadcast(_team_id, _table, _data), do: :ok

  def for_team(team_id) when is_integer(team_id) do
    team = Teams.get_team(team_id)

    Map.new(@fields, fn {table, field} ->
      case team && team[field] && Plans.get(table, team[field]) do
        %{data: data} -> {table, count(table, data)}
        _ -> {table, 0}
      end
    end)
  end

  def for_team(_team_id), do: %{}

  def count(:battle_plans, %{"playbooks" => playbooks}) when is_list(playbooks), do: length(playbooks)

  def count(:pack_plans, %{"packs" => packs}) when is_map(packs) do
    Enum.sum(for {_pack, modes} <- packs, is_map(modes), {_mode, %{"priority" => "hunt"}} <- modes, do: 1)
  end

  def count(:gift_plans, %{"milestones" => milestones}) when is_list(milestones) do
    milestones |> Enum.map(&length(&1["entries"] || [])) |> Enum.sum()
  end

  def count(_table, _data), do: 0
end
