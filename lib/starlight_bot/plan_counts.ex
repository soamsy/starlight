defmodule StarlightBot.PlanCounts do
  alias StarlightBot.{Plans, Teams}

  @topic "plan_counts"
  @tables ~w(battle_plans pack_plans gift_plans)a

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def broadcast(team_id, table, data) when is_integer(team_id) do
    Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, {:plan_count, team_id, table, count(table, data)})
  end

  def broadcast(_team_id, _table, _data), do: :ok

  def for_team(team_id) when is_integer(team_id) do
    team = Teams.get_team(team_id)

    Map.new(@tables, fn table ->
      case Plans.for_team(team, table) do
        %{data: data} -> {table, count(table, data)}
        _ -> {table, 0}
      end
    end)
  end

  def for_team(_team_id), do: %{}

  def count(:battle_plans, %{"playbooks" => playbooks}) when is_list(playbooks), do: length(playbooks)

  def count(:pack_plans, %{"packs" => packs}) when is_map(packs) do
    Enum.sum(for {_pack, modes} <- packs, is_map(modes), {_mode, floors} <- modes, is_map(floors), Enum.any?(floors, fn {_floor, status} -> status in ~w(hunt favorite) end), do: 1)
  end

  def count(:gift_plans, %{"milestones" => milestones}) when is_list(milestones) do
    milestones |> Enum.map(&length(&1["entries"] || [])) |> Enum.sum()
  end

  def count(_table, _data), do: 0
end
