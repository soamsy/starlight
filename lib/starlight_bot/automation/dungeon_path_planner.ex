defmodule StarlightBot.Automation.DungeonPathPlanner do
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx
  alias StarlightBot.Input.Keyboard
  alias StarlightBot.Vision.{Capture, DungeonGraph}

  @levels DungeonGraph.levels()

  @node_cost %{event: 0, battle: 52, hard_battle: 87, shop: 20, boss: 0}

  @spec navigate_to_next_node(term, Ctx.t()) :: {:ok, term} | {:error, term}
  def navigate_to_next_node(_last_frame, ctx) do
    case build_graph(ctx) do
      {:ok, graph} -> align_toward_best_target(graph, ctx)
      {:error, reason} -> skip_alignment(ctx, reason)
    end
  end

  defp align_toward_best_target(graph, ctx) do
    case choose_target_level(graph) do
      {:ok, target_level} ->
        align_camera(graph.current_level, target_level, ctx)
        {:ok, nil}

      {:error, reason} ->
        skip_alignment(ctx, reason)
    end
  end

  defp skip_alignment(ctx, reason) do
    Ctx.log(ctx, :info, "dungeon path planner: #{inspect(reason)} — pressing forward with no alignment")
    {:ok, nil}
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

  @spec choose_target_level(DungeonGraph.t()) :: {:ok, atom} | {:error, term}
  def choose_target_level(%DungeonGraph{current_level: nil}), do: {:error, :no_current_level}

  def choose_target_level(%DungeonGraph{current_level: current, nodes: nodes, edges: edges}) do
    case edges_from({0, current}, edges) do
      [] ->
        {:error, :no_forward_edges}

      candidates ->
        {best, _cost} =
          candidates
          |> Enum.map(&{&1, total_cost(&1, nodes, edges)})
          |> Enum.min_by(fn {_edge, cost} -> cost end)

        {:ok, elem(best.to_node, 1)}
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

  defp align_camera(current_level, target_level, ctx) do
    current_idx = Enum.find_index(@levels, &(&1 == current_level))
    target_idx = Enum.find_index(@levels, &(&1 == target_level))
    do_align(current_idx, target_idx, target_level, ctx)
  end

  defp do_align(nil, _target_idx, _target_level, _ctx), do: :ok
  defp do_align(_current_idx, nil, _target_level, _ctx), do: :ok
  defp do_align(idx, idx, _target_level, _ctx), do: :ok

  defp do_align(current_idx, target_idx, target_level, ctx) when target_idx > current_idx do
    Ctx.log(ctx, :info, "dungeon path planner: aligning up to #{target_level}")
    Keyboard.press(:w, target_idx - current_idx)
  end

  defp do_align(current_idx, target_idx, target_level, ctx) do
    Ctx.log(ctx, :info, "dungeon path planner: aligning down to #{target_level}")
    Keyboard.press(:s, current_idx - target_idx)
  end
end
