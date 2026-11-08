defmodule StarlightBot.PlanCounts do
  alias StarlightBot.{Plans, Teams}

  @topic "plan_counts"
  @tables ~w(battle_plans pack_plans gift_plans)a

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def broadcast(team_id, :starlight_net, net) when is_integer(team_id) do
    :persistent_term.put({__MODULE__, :starlight_net, team_id}, net)
    Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, {:plan_count, team_id, :starlight_net, net})
  end

  def broadcast(team_id, table, data) when is_integer(team_id) do
    Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, {:plan_count, team_id, table, count(table, data)})
  end

  def broadcast(_team_id, _table, _data), do: :ok

  def for_team(team_id) when is_integer(team_id) do
    team = Teams.get_team(team_id)

    @tables
    |> Map.new(fn table ->
      case Plans.for_team(team, table) do
        %{data: data} -> {table, count(table, data)}
        _ -> {table, 0}
      end
    end)
    |> put_net(team_id)
  end

  def for_team(_team_id), do: %{}

  defp put_net(counts, team_id) do
    case :persistent_term.get({__MODULE__, :starlight_net, team_id}, nil) do
      nil -> counts
      net -> Map.put(counts, :starlight_net, net)
    end
  end

  def count(:battle_plans, %{"playbooks" => playbooks}) when is_list(playbooks), do: length(playbooks)

  def count(:pack_plans, %{"packs" => packs}) when is_map(packs) do
    Enum.sum(for {_pack, modes} <- packs, is_map(modes), {_mode, floors} <- modes, is_map(floors), Enum.any?(floors, fn {_floor, status} -> status in ~w(hunt favorite) end), do: 1)
  end

  def count(:gift_plans, %{"milestones" => milestones}) when is_list(milestones) do
    milestones |> Enum.map(&length(&1["entries"] || [])) |> Enum.sum()
  end

  def count(_table, _data), do: 0
end
