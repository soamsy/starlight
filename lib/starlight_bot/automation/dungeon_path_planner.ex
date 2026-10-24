defmodule StarlightBot.Automation.DungeonPathPlanner do
  alias StarlightBot.Automation.Engine
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{RewardHelpers, RunMemory}
  alias StarlightBot.BattlePlans
  alias StarlightBot.BattlePlans.Resolver
  alias StarlightBot.Ctx
  alias StarlightBot.Vision.{Capture, DungeonGraph, Matcher}

  @levels DungeonGraph.levels()
  @ready_timeout_ms 3_000
  @ready_poll_ms 50
  @shop_confirm_wait_ms 1_500
  @arrival_space_ms 80
  @arrival_timeout_ms 4_000
  @node_arrival_hooks [
    :event, :shop, :shop_super, :ego_gift_get, :team_selector, :team_selector_tall, :team_selector_gone, :loading_stage_1, :loading_stage_2
  ]

  @node_cost %{event: 10, battle: 15, hard_battle: 18, risky_battle: 25, shop: 10, boss: 50}

  @spec navigate_to_next_node(term, Ctx.t()) :: {:ok, term} | {:error, term}
  def navigate_to_next_node(_last_frame, ctx) do
    graph_result = build_graph(ctx)

    with {:ok, graph} <- graph_result, true <- DungeonGraph.boss_next?(graph) do
      Ctx.log(ctx, :info, "dungeon path planner: at most one mid node ahead, marking boss next")
      RunMemory.put_bosses_only(ctx, true)
    end

    boss? = RunMemory.bosses_only?(ctx)
    venue = if boss?, do: "md_boss", else: "md_battle"
    RunMemory.put_venue(ctx, venue)

    {direction, kind} =
      case graph_result do
        {:ok, graph} -> graph |> recall(ctx) |> best_move(ctx)
        {:error, reason} -> default_move(ctx, reason)
      end

    kind = if boss?, do: :boss, else: kind
    advance(direction, kind, venue, [], ctx)
  end

  @spec leave_shop_for_boss(Ctx.t()) :: {:ok, term} | {:error, term}
  def leave_shop_for_boss(ctx) do
    RunMemory.put_venue(ctx, "md_boss")
    shop_exit = [{:shop_leave_confirm, [key(:enter)]}, {:shop, [click(:shop_leave)]}]

    with {:ok, _} <- Engine.act([click(:shop_leave), branch([{:shop_leave_confirm, []}], wait: @shop_confirm_wait_ms)], ctx) do
      advance(:d, :boss, "md_boss", shop_exit, ctx)
    end
  end

  defp advance(direction, kind, venue, leading_clauses, ctx) do
    cond do
    kind in [:battle, :hard_battle, :risky_battle, :boss] and formation_set?(venue, ctx) ->
      Ctx.log(ctx, :info, "dungeon path planner: #{kind} ahead, sinner order already set — spamming #{direction} + enter until loading")

      Engine.act([
        retry_until(any_of([:loading_stage_1, :loading_stage_2]), [
          branch(leading_clauses ++ [gift_popup_clause(), {:default, [key(direction), key(:enter)]}])
        ], every: 100, timeout: 10_000)
      ] ++ loading() ++ [await(:battle_settings, timeout: 5_000, premove: false)], ctx)
    kind in [:battle, :hard_battle, :risky_battle, :boss] ->
      Ctx.log(ctx, :info, "dungeon path planner: #{kind} ahead, moving to team select")

      Engine.act([
        retry_until(any_of([:team_selector, :team_selector_tall, :team_selector_gone]),
        [
          branch(leading_clauses ++ [
            gift_popup_clause(),
            {:dungeon_graph_dante, [key(direction), key(:enter), sleep(200)]},
            {:dungeon_graph_enter_dante, [key(:enter)]},
            {:default, [key(:enter)]}
          ])
        ],
        every: 100,
        timeout: 5_000)
      ], ctx)
    true ->
      Ctx.log(ctx, :info, "dungeon path planner: #{kind} ahead (#{venue}), spamming #{direction} + enter until dungeon_graph is gone, then space + enter until it shows")

      Engine.act([
        retry_until(not_hook(:dungeon_graph),
        [
          branch(leading_clauses ++ [
            gift_popup_clause(),
            {:default, [key(direction), key(:enter)]}
          ])
        ],
        every: 80,
        timeout: 4_000),
        attempt([retry_until(any_of(@node_arrival_hooks), [key(:space), key(:enter)], every: @arrival_space_ms, timeout: @arrival_timeout_ms)], else: [])
      ], ctx)
    end
  end

  defp gift_popup_clause, do: {:ego_gift_get, [RewardHelpers.record_ego_gift_items_step(), key(:enter)]}

  defp formation_set?(venue, ctx) do
    stored = RunMemory.formation(ctx)

    case Resolver.lineup_for(RunMemory.battle_plan(ctx), venue, RunMemory.floor(ctx)) do
      %{"sinners" => [_ | _] = sinners} -> stored != nil and BattlePlans.formation(sinners) == stored
      _ -> false
    end
  end

  defp recall(graph, ctx) do
    floor = RunMemory.floor(ctx)

    case RunMemory.dungeon_map(ctx) do
      {^floor, remembered} ->
        remembered_targets = hop_0_targets(remembered.edges)
        seen_targets = hop_0_targets(graph.edges)

        if remembered_targets == seen_targets do
          merged = DungeonGraph.merge_remembered(graph, remembered)
          added = length(merged.edges) - length(graph.edges)
          if added > 0, do: Ctx.log(ctx, :info, "dungeon path planner: #{added} remembered edge(s) out of view, keeping them")
          merged
        else
          only_remembered = hop_0_edges_to(remembered.edges, MapSet.difference(remembered_targets, seen_targets))
          only_seen = hop_0_edges_to(graph.edges, MapSet.difference(seen_targets, remembered_targets))

          Ctx.log(
            ctx,
            :info,
            "dungeon path planner: remembered map disagrees with this view (current #{graph.current_level}), dropping it; " <>
              "remembered only: #{describe_edges(only_remembered)}; seen only: #{describe_edges(only_seen)}"
          )

          graph
        end

      _ ->
        graph
    end
  end

  defp hop_0_targets(edges), do: edges |> Enum.filter(&match?({0, _}, &1.from_node)) |> MapSet.new(& &1.to_node)

  defp hop_0_edges_to(edges, targets), do: Enum.filter(edges, &(match?({0, _}, &1.from_node) and MapSet.member?(targets, &1.to_node)))

  defp describe_edges([]), do: "none"

  defp describe_edges(edges) do
    Enum.map_join(edges, ", ", fn %{from_node: {_, from}, to_node: {_, to}} = edge ->
      "#{from}->#{to} (#{edge.hook} #{:erlang.float_to_binary(edge.score * 1.0, decimals: 3)})"
    end)
  end

  defp best_move(graph, ctx) do
    case choose_target(graph) do
      {:ok, edge} ->
        target_level = elem(edge.to_node, 1)
        RunMemory.put_dungeon_map(ctx, {RunMemory.floor(ctx), DungeonGraph.advance_view(graph, target_level)})
        {direction_key(graph.current_level, target_level), edge_kind(edge, graph.nodes)}

      {:error, reason} ->
        default_move(ctx, reason)
    end
  end

  defp default_move(ctx, reason) do
    RunMemory.put_dungeon_map(ctx, nil)
    Ctx.log(ctx, :info, "dungeon path planner: #{inspect(reason)} — defaulting to d")
    {:d, :unknown}
  end

  defp build_graph(ctx) do
    started_at = System.monotonic_time(:millisecond)

    case await_ready_graph(started_at + @ready_timeout_ms, ctx) do
      {:error, :pan_zoom_not_reset} ->
        Ctx.log(ctx, :info, "dungeon path planner: pan/zoom never settled — resetting view")
        Engine.run_action(:dungeon_graph, :reset_view, ctx)
        grab_and_build()

      {:ok, %DungeonGraph{current_level: level}} = ok when level != nil ->
        waited = System.monotonic_time(:millisecond) - started_at
        if waited >= @ready_poll_ms, do: Ctx.log(ctx, :info, "dungeon path planner: graph ready after #{waited}ms")
        ok

      other ->
        other
    end
  end

  defp await_ready_graph(deadline, ctx) do
    with {:ok, frame} <- Capture.grab_frame() do
      if Matcher.check(frame, :ego_gift_get) do
        RewardHelpers.record_ego_gift_items(frame, ctx)
        Engine.act([key(:enter)], ctx)
        await_ready_graph(deadline, ctx)
      else
        case DungeonGraph.build(frame) do
          {:ok, %DungeonGraph{current_level: level}} = ok when level != nil ->
            ok

          result ->
            if System.monotonic_time(:millisecond) >= deadline do
              result
            else
              Process.sleep(@ready_poll_ms)
              await_ready_graph(deadline, ctx)
            end
        end
      end
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
        {:ok, best_step(candidates, nodes, edges)}
    end
  end

  @spec planned_path(DungeonGraph.t()) :: {:ok, [map]} | {:error, term}
  def planned_path(%DungeonGraph{nodes: nodes, edges: edges} = graph) do
    with {:ok, first} <- choose_target(graph) do
      {:ok, [first | continuation(first.to_node, nodes, edges)]}
    end
  end

  defp continuation(node, nodes, edges) do
    case edges_from(node, edges) do
      [] -> []
      candidates -> candidates |> best_step(nodes, edges) |> then(&[&1 | continuation(&1.to_node, nodes, edges)])
    end
  end

  defp best_step(candidates, nodes, edges) do
    horizon = edges |> Enum.map(&elem(&1.to_node, 0)) |> Enum.max()
    Enum.min_by(candidates, &step_rank(&1, nodes, edges, horizon))
  end

  defp step_rank(edge, nodes, edges, horizon) do
    costs = edge |> full_paths(edges) |> Enum.map(&(path_cost(&1, nodes) + unseen_cost(List.last(&1), horizon)))
    cheapest = Enum.min(costs)
    {cheapest, -Enum.count(costs, &(&1 == cheapest)), -MapSet.size(reachable_from(edge.to_node, edges))}
  end

  defp full_paths(edge, edges) do
    case edges_from(edge.to_node, edges) do
      [] -> [[edge]]
      next -> for n <- next, rest <- full_paths(n, edges), do: [edge | rest]
    end
  end

  defp unseen_cost(%{variant: variant}, _horizon) when variant in [:boss, :shop], do: 0
  defp unseen_cost(%{to_node: {hop, _}}, horizon), do: (horizon - hop) * @node_cost.battle

  defp path_cost(path, nodes), do: path |> Enum.map(&edge_cost(&1, nodes)) |> Enum.sum()

  defp reachable_from(node, edges) do
    node
    |> edges_from(edges)
    |> Enum.reduce(MapSet.new(), &(&2 |> MapSet.put(&1.to_node) |> MapSet.union(reachable_from(&1.to_node, edges))))
  end

  defp edge_kind(%{variant: variant}, _nodes) when variant in [:boss, :shop], do: variant

  defp edge_kind(edge, nodes) do
    case Map.get(nodes, edge.to_node) do
      %{type: type} -> type
      nil -> :event
    end
  end

  defp edges_from(node, edges), do: Enum.filter(edges, &(&1.from_node == node))

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
