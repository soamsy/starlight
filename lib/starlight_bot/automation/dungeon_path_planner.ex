defmodule StarlightBot.Automation.DungeonPathPlanner do
  alias StarlightBot.Automation.Engine
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{RewardHelpers, RunMemory}
  alias StarlightBot.BattleStrategies
  alias StarlightBot.BattleStrategies.Resolver
  alias StarlightBot.Ctx
  alias StarlightBot.Vision.{Capture, DungeonGraph}

  @levels DungeonGraph.levels()

  @node_cost %{event: 0, battle: 52, hard_battle: 87, shop: 20, boss: 0}

  @spec navigate_to_next_node(term, Ctx.t()) :: {:ok, term} | {:error, term}
  def navigate_to_next_node(_last_frame, ctx) do
    boss? = RunMemory.bosses_only?(ctx)
    venue = if boss?, do: "md_boss", else: "md_battle"
    RunMemory.put_venue(ctx, venue)

    {direction, kind} =
      case build_graph(ctx) do
        {:ok, graph} -> best_move(graph, ctx)
        {:error, reason} -> default_move(ctx, reason)
      end

    kind = if boss?, do: :boss, else: kind

    cond do
    kind in [:battle, :hard_battle, :boss] and formation_set?(venue, ctx) ->
      Ctx.log(ctx, :info, "dungeon path planner: #{kind} ahead, sinner order already set — spamming #{direction} + enter until loading")

      Engine.act([
        retry_until(any_of([:loading_stage_1, :loading_stage_2]), [
          branch([gift_popup_clause(), {:default, [key(direction), key(:enter)]}])
        ], every: 200, timeout: 15_000)
      ] ++ loading(), ctx)
    kind in [:battle, :hard_battle, :boss] ->
      Ctx.log(ctx, :info, "dungeon path planner: #{kind} ahead, moving to team select")

      Engine.act([
        retry_until(any_of([:team_selector, :team_selector_tall, :team_selector_gone]),
        [
          branch([
            gift_popup_clause(),
            {:dungeon_graph_dante, [key(direction), key(:enter), sleep(200), key(direction), key(:enter)]},
            {:default, [key(:enter)]}
          ])
        ],
        every: 1_000,
        timeout: 10_000)
      ], ctx)
    true ->
      Ctx.log(ctx, :info, "dungeon path planner: #{kind} ahead (#{venue}), spamming #{direction} + enter until dungeon_graph is gone")

      Engine.act([
        retry_until(not_hook(:dungeon_graph),
        [
          branch([
            gift_popup_clause(),
            {:dungeon_graph_dante, [key(direction), key(:enter), sleep(200), key(direction), key(:enter)]},
            {:default, [key(:enter)]}
          ])
        ],
        every: 700,
        timeout: 5_000)
      ], ctx)
    end
  end

  defp gift_popup_clause, do: {:ego_gift_get, [RewardHelpers.record_ego_gift_items_step(), key(:enter)]}

  defp formation_set?(venue, ctx) do
    stored = RunMemory.formation(ctx)

    case Resolver.lineup_for(RunMemory.battle_strategy(ctx), venue, RunMemory.floor(ctx)) do
      %{"sinners" => [_ | _] = sinners} -> stored != nil and BattleStrategies.formation(sinners) == stored
      _ -> false
    end
  end

  defp best_move(graph, ctx) do
    case choose_target(graph) do
      {:ok, edge} -> {direction_key(graph.current_level, elem(edge.to_node, 1)), edge_kind(edge, graph.nodes)}
      {:error, reason} -> default_move(ctx, reason)
    end
  end

  defp default_move(ctx, reason) do
    Ctx.log(ctx, :info, "dungeon path planner: #{inspect(reason)} — defaulting to d")
    {:d, :unknown}
  end

  defp build_graph(ctx) do
    case grab_and_build() do
      {:error, :pan_zoom_not_reset} ->
        Ctx.log(ctx, :info, "dungeon path planner: pan/zoom drifted — resetting view")
        Engine.run_action(:dungeon_graph, :reset_view, ctx)
        grab_and_build()

      other ->
        other
    end
  end

  defp grab_and_build do
    with {:ok, frame} <- Capture.grab_frame() do
      DungeonGraph.build(frame)
    end
  end

  @spec choose_target(DungeonGraph.t()) :: {:ok, map} | {:error, term}
  def choose_target(%DungeonGraph{current_level: nil}), do: {:error, :no_current_level}

  def choose_target(%DungeonGraph{current_level: current, nodes: nodes, edges: edges}) do
    case edges_from({0, current}, edges) do
      [] ->
        {:error, :no_forward_edges}

      candidates ->
        {best, _cost} =
          candidates
          |> Enum.map(&{&1, total_cost(&1, nodes, edges)})
          |> Enum.min_by(fn {_edge, cost} -> cost end)

        {:ok, best}
    end
  end

  defp edge_kind(%{variant: variant}, _nodes) when variant in [:boss, :shop], do: variant

  defp edge_kind(edge, nodes) do
    case Map.get(nodes, edge.to_node) do
      %{type: type} -> type
      nil -> :event
    end
  end

  defp edges_from(node, edges), do: Enum.filter(edges, &(&1.from_node == node))

  defp total_cost(edge, nodes, edges), do: edge_cost(edge, nodes) + continuation_cost(edge.to_node, nodes, edges)

  defp continuation_cost(node, nodes, edges) do
    case edges_from(node, edges) do
      [] -> 0
      next -> next |> Enum.map(&edge_cost(&1, nodes)) |> Enum.min()
    end
  end

  defp edge_cost(%{variant: :boss}, _nodes), do: @node_cost.boss
  defp edge_cost(%{variant: :shop}, _nodes), do: @node_cost.shop

  defp edge_cost(edge, nodes) do
    case Map.get(nodes, edge.to_node) do
      %{type: type} -> Map.get(@node_cost, type, @node_cost.event)
      nil -> @node_cost.event
    end
  end

  defp direction_key(current_level, target_level) do
    current_idx = Enum.find_index(@levels, &(&1 == current_level))
    target_idx = Enum.find_index(@levels, &(&1 == target_level))
    direction_for(current_idx, target_idx)
  end

  defp direction_for(nil, _target_idx), do: :d
  defp direction_for(_current_idx, nil), do: :d
  defp direction_for(current_idx, target_idx) when target_idx > current_idx, do: :w
  defp direction_for(current_idx, target_idx) when target_idx < current_idx, do: :s
  defp direction_for(_current_idx, _target_idx), do: :d
end
