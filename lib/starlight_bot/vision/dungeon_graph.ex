defmodule StarlightBot.Vision.DungeonGraph do
  alias StarlightBot.Vision.{Frame, HookRegistry, Matcher}

  @levels [:lowest, :low, :mid, :high, :highest]

  @coin_hooks [
    :dungeon_graph_node_mid_coin_some,
    :dungeon_graph_node_mid_far_coin,
    :dungeon_graph_node_low_coin_all,
    :dungeon_graph_node_high_coin_all
  ]

  @coin_hook_level %{
    dungeon_graph_node_mid_coin_some: :mid,
    dungeon_graph_node_mid_far_coin: :mid,
    dungeon_graph_node_low_coin_all: :low,
    dungeon_graph_node_high_coin_all: :high
  }

  @coin_x_regions %{1 => {990, 1190}, 2 => {1370, 1570}, 3 => {1760, 1920}}
  @coin_center_tolerance_px 25

  @enforce_keys [:nodes, :edges, :diagnostics, :warnings, :node_hits]
  defstruct [:floor, :current_level, :nodes, :edges, :diagnostics, :warnings, :node_hits]

  def levels, do: @levels

  def build(%Frame{} = frame) do
    cond do
      not Matcher.check(frame, :dungeon_graph) ->
        {:error, :not_on_dungeon_graph}

      not Matcher.check(frame, :dungeon_graph_dante) ->
        {:error, :pan_zoom_not_reset}

      true ->
        {:ok, build_matched(frame)}
    end
  end

  defp build_matched(frame) do
    matches =
      HookRegistry.all_names()
      |> edge_specs()
      |> Enum.flat_map(fn spec ->
        Enum.map(spec.variants, fn {variant, hook_name} ->
          match_hook(frame, hook_name, spec, variant)
        end)
      end)

    graph = build_from_matches(matches)
    hits = classify_hits(coin_hits_by_hook(frame))

    %{
      graph
      | nodes: apply_hits_to_nodes(graph.nodes, hits),
        node_hits: hits,
        floor: detect_floor(frame)
    }
  end

  defp coin_hits_by_hook(frame) do
    Map.new(@coin_hooks, fn hook_name -> {hook_name, Matcher.find_all(frame, hook_name)} end)
  end

  defp match_hook(frame, hook_name, spec, variant) do
    region = hook_region(hook_name)

    case Matcher.find_with_score(frame, hook_name) do
      {:ok, score, match} ->
        %{
          hook: hook_name,
          hop: spec.hop,
          from: spec.from,
          to: spec.to,
          variant: variant,
          matched?: match != :not_found,
          score: score,
          rect: rect_from(match),
          region: region
        }

      {:error, :hook_not_found} ->
        %{
          hook: hook_name,
          hop: spec.hop,
          from: spec.from,
          to: spec.to,
          variant: variant,
          matched?: false,
          score: 0.0,
          rect: nil,
          region: region
        }
    end
  end

  defp hook_region(hook_name) do
    case HookRegistry.find(hook_name) do
      {:ok, hook} -> hook.region
      {:error, :not_found} -> nil
    end
  end

  defp rect_from({:ok, rect}), do: rect
  defp rect_from(:not_found), do: nil

  defp detect_floor(frame) do
    if Matcher.check(frame, :dungeon_graph_floor_1), do: 1, else: nil
  end

  def parse_hook_name(name) when is_atom(name), do: parse_hook_name(Atom.to_string(name))

  def parse_hook_name("dungeon_graph_" <> rest) do
    case String.split(rest, "_") do
      [hop_str, from_str, to_str | tail] ->
        with {hop, ""} <- Integer.parse(hop_str),
             from_atom = String.to_atom(from_str),
             true <- from_atom in @levels do
          build_edge_spec(hop, from_atom, to_str, tail)
        else
          _ -> :not_a_path_hook
        end

      _ ->
        :not_a_path_hook
    end
  end

  def parse_hook_name(_), do: :not_a_path_hook

  defp build_edge_spec(hop, from, to_str, tail) do
    to_atom = String.to_atom(to_str)

    cond do
      to_atom in @levels ->
        variant = if tail == [], do: nil, else: tail |> Enum.join("_") |> String.to_atom()
        {:ok, %{hop: hop, from: from, to: to_atom, variant: variant}}

      tail == [] ->
        {:ok, %{hop: hop, from: from, to: from, variant: to_atom}}

      true ->
        :not_a_path_hook
    end
  end

  def edge_specs(hook_names) do
    hook_names
    |> Enum.reduce(%{}, fn name, acc ->
      case parse_hook_name(name) do
        {:ok, %{hop: hop, from: from}} when hop == 0 and from != :mid ->
          acc

        {:ok, %{hop: hop, from: from, to: to, variant: variant}} ->
          Map.update(acc, {hop, from, to}, [{variant, name}], &[{variant, name} | &1])

        :not_a_path_hook ->
          acc
      end
    end)
    |> Enum.map(fn {{hop, from, to}, variants} ->
      %{hop: hop, from: from, to: to, variants: Enum.reverse(variants)}
    end)
  end

  def build_from_matches(matches) do
    accepted =
      matches
      |> Enum.group_by(&{&1.hop, &1.from, &1.to})
      |> Enum.flat_map(fn {key, entries} -> accept_edge(key, entries) end)
      |> Map.new(&{{&1.from_node, &1.to_node}, &1})

    {current_level, level_warnings} = current_level_and_warnings(accepted)

    {reachable, orphaned} =
      case current_level do
        nil ->
          {[], Map.values(accepted)}

        level ->
          visited = reachable_nodes(accepted, {0, level})
          partition_edges(accepted, visited)
      end

    orphan_warning = if orphaned == [], do: [], else: [:orphan_edges_excluded]

    %__MODULE__{
      floor: nil,
      current_level: current_level,
      nodes: nodes_from_edges(reachable),
      edges: reachable,
      diagnostics: matches,
      warnings: level_warnings ++ orphan_warning,
      node_hits: []
    }
  end

  def classify_hits(hits_by_hook) do
    hits_by_hook
    |> Enum.flat_map(fn {hook_name, rects} -> Enum.map(rects, &coin_hit(hook_name, &1)) end)
    |> Enum.reject(&is_nil/1)
  end

  defp coin_hit(hook_name, {x, y, w, h}) do
    cx = x + div(w, 2)

    case Enum.find(@coin_x_regions, fn {_hop, {lo, hi}} -> cx >= lo and cx < hi end) do
      nil ->
        nil

      {hop, {lo, hi}} ->
        center = div(lo + hi, 2)

        %{
          level: Map.fetch!(@coin_hook_level, hook_name),
          hop: hop,
          hook: hook_name,
          rect: {x, y, w, h},
          centered?: abs(cx - center) <= @coin_center_tolerance_px
        }
    end
  end

  def apply_hits_to_nodes(nodes, hits) do
    hits_by_slot = Map.new(hits, &{{&1.level, &1.hop}, &1})

    Map.new(nodes, fn {{hop, level} = key, node} ->
      {key, apply_node_type(node, Map.get(hits_by_slot, {level, hop}))}
    end)
  end

  defp apply_node_type(node, nil), do: node
  defp apply_node_type(node, %{centered?: true}), do: %{node | type: :battle}
  defp apply_node_type(node, %{centered?: false}), do: %{node | type: :hard_battle}

  defp accept_edge({hop, from, to}, entries) do
    case Enum.filter(entries, & &1.matched?) do
      [] ->
        []

      matched ->
        best = Enum.max_by(matched, & &1.score)

        [
          %{
            from_node: {hop, from},
            to_node: {hop + 1, to},
            hook: best.hook,
            variant: best.variant,
            score: best.score,
            rect: best.rect
          }
        ]
    end
  end

  defp current_level_and_warnings(accepted) do
    hop0_levels =
      accepted
      |> Map.values()
      |> Enum.filter(&match?({0, _}, &1.from_node))
      |> Enum.map(&elem(&1.from_node, 1))
      |> Enum.uniq()

    case hop0_levels do
      [] -> {nil, [:no_paths_found]}
      [level] -> {level, []}
      [level | _] -> {level, [:inconsistent_current_level]}
    end
  end

  defp reachable_nodes(accepted, start_node) do
    adjacency = accepted |> Map.values() |> Enum.group_by(& &1.from_node)
    bfs(adjacency, [start_node], MapSet.new([start_node]))
  end

  defp bfs(_adjacency, [], visited), do: visited

  defp bfs(adjacency, [node | rest], visited) do
    neighbors =
      adjacency
      |> Map.get(node, [])
      |> Enum.map(& &1.to_node)
      |> Enum.reject(&MapSet.member?(visited, &1))

    bfs(adjacency, rest ++ neighbors, Enum.reduce(neighbors, visited, &MapSet.put(&2, &1)))
  end

  defp partition_edges(accepted, visited) do
    accepted
    |> Map.values()
    |> Enum.split_with(&MapSet.member?(visited, &1.from_node))
  end

  defp nodes_from_edges(edges) do
    edges
    |> Enum.flat_map(&[&1.from_node, &1.to_node])
    |> Enum.uniq()
    |> Map.new(fn {hop, level} -> {{hop, level}, %{hop: hop, level: level, type: :event}} end)
  end
end
