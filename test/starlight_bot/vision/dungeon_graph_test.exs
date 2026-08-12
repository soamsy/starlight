defmodule StarlightBot.Vision.DungeonGraphTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.DungeonGraph

  describe "parse_hook_name/1" do
    test "plain level-pair hook" do
      assert DungeonGraph.parse_hook_name("dungeon_graph_1_mid_mid") ==
               {:ok, %{hop: 1, from: :mid, to: :mid, variant: nil}}
    end

    test "level-pair hook with a trailing variant" do
      assert DungeonGraph.parse_hook_name("dungeon_graph_2_mid_mid_hard") ==
               {:ok, %{hop: 2, from: :mid, to: :mid, variant: :hard}}
    end

    test "special marker in the 'to' slot implies a same-lane edge" do
      assert DungeonGraph.parse_hook_name("dungeon_graph_1_mid_shop") ==
               {:ok, %{hop: 1, from: :mid, to: :mid, variant: :shop}}

      assert DungeonGraph.parse_hook_name("dungeon_graph_1_high_warning") ==
               {:ok, %{hop: 1, from: :high, to: :high, variant: :warning}}

      assert DungeonGraph.parse_hook_name("dungeon_graph_2_mid_boss") ==
               {:ok, %{hop: 2, from: :mid, to: :mid, variant: :boss}}
    end

    test "accepts an atom name" do
      assert DungeonGraph.parse_hook_name(:dungeon_graph_0_mid_high) ==
               {:ok, %{hop: 0, from: :mid, to: :high, variant: nil}}
    end

    test "rejects non-path dungeon_graph hooks" do
      for name <- ~w(dungeon_graph_dante dungeon_graph_enter dungeon_graph_node_slash
                     dungeon_graph_floor_1 dungeon_graph_boss_next dungeon_graph_clear_rewards_150) do
        assert DungeonGraph.parse_hook_name(name) == :not_a_path_hook, name
      end
    end

    test "rejects hooks outside the dungeon_graph namespace" do
      assert DungeonGraph.parse_hook_name("battle_chain") == :not_a_path_hook
    end
  end

  describe "edge_specs/1" do
    test "groups same-slot variant hooks under one edge spec" do
      specs =
        DungeonGraph.edge_specs([
          :dungeon_graph_1_mid_mid,
          :dungeon_graph_1_mid_shop,
          :dungeon_graph_1_mid_warning,
          :dungeon_graph_1_mid_high,
          :dungeon_graph_dante
        ])

      mid_mid = Enum.find(specs, &(&1.hop == 1 and &1.from == :mid and &1.to == :mid))
      mid_high = Enum.find(specs, &(&1.hop == 1 and &1.from == :mid and &1.to == :high))

      assert length(specs) == 2

      assert Enum.sort(mid_mid.variants) ==
               Enum.sort([
                 {nil, :dungeon_graph_1_mid_mid},
                 {:shop, :dungeon_graph_1_mid_shop},
                 {:warning, :dungeon_graph_1_mid_warning}
               ])

      assert mid_high.variants == [{nil, :dungeon_graph_1_mid_high}]
    end

    test "drops hop-0 hooks whose 'from' isn't mid — the user's own node is always screen-centered" do
      specs =
        DungeonGraph.edge_specs([
          :dungeon_graph_0_mid_high,
          :dungeon_graph_0_low_low,
          :dungeon_graph_0_low_mid,
          :dungeon_graph_0_low_lowest,
          :dungeon_graph_0_high_mid,
          :dungeon_graph_0_high_high,
          :dungeon_graph_0_lowest_low
        ])

      assert Enum.map(specs, &{&1.hop, &1.from, &1.to}) == [{0, :mid, :high}]
    end
  end

  describe "build_from_matches/1" do
    defp match(hop, from, to, opts) do
      %{
        hook: Keyword.get(opts, :hook, :"dungeon_graph_#{hop}_#{from}_#{to}"),
        hop: hop,
        from: from,
        to: to,
        variant: Keyword.get(opts, :variant),
        matched?: Keyword.get(opts, :matched?, true),
        score: Keyword.get(opts, :score, 0.9),
        rect: Keyword.get(opts, :rect, {0, 0, 1, 1})
      }
    end

    test "builds a straightforward 3-hop mid-lane DAG" do
      matches = [
        match(0, :mid, :mid, []),
        match(1, :mid, :mid, []),
        match(2, :mid, :mid, variant: :hard)
      ]

      graph = DungeonGraph.build_from_matches(matches)

      assert graph.current_level == :mid
      assert graph.warnings == []
      assert map_size(graph.nodes) == 4
      assert Map.has_key?(graph.nodes, {0, :mid})
      assert Map.has_key?(graph.nodes, {3, :mid})
      assert graph.nodes[{3, :mid}].type == :event
      assert length(graph.edges) == 3
    end

    test "an unmatched plain hook still produces an edge via its shop variant" do
      matches = [
        match(0, :mid, :mid, []),
        match(1, :mid, :mid, matched?: false, hook: :dungeon_graph_1_mid_mid),
        match(1, :mid, :mid, variant: :shop, hook: :dungeon_graph_1_mid_shop, score: 0.95)
      ]

      graph = DungeonGraph.build_from_matches(matches)

      edge = Enum.find(graph.edges, &(&1.from_node == {1, :mid}))
      assert edge.hook == :dungeon_graph_1_mid_shop
      assert edge.variant == :shop
    end

    test "excludes edges unreachable from the current position, but keeps them as diagnostics" do
      matches = [
        match(0, :mid, :mid, []),
        match(1, :high, :high, hook: :dungeon_graph_1_high_high)
      ]

      graph = DungeonGraph.build_from_matches(matches)

      assert graph.current_level == :mid
      refute Enum.any?(graph.edges, &(&1.from_node == {1, :high}))
      refute Map.has_key?(graph.nodes, {1, :high})
      assert :orphan_edges_excluded in graph.warnings
      assert Enum.any?(graph.diagnostics, &(&1.hook == :dungeon_graph_1_high_high))
    end

    test "no matched hop-0 edges yields an empty graph with a warning" do
      matches = [match(0, :mid, :mid, matched?: false)]

      graph = DungeonGraph.build_from_matches(matches)

      assert graph.current_level == nil
      assert graph.nodes == %{}
      assert graph.edges == []
      assert :no_paths_found in graph.warnings
    end
  end

  describe "classify_hits/1" do
    test "a coin centered in its hop column is centered?: true" do
      hits =
        DungeonGraph.classify_hits(%{
          dungeon_graph_node_mid_coin_some: [{1070, 337, 40, 20}]
        })

      assert [%{level: :mid, hop: 1, centered?: true}] = hits
    end

    test "a coin offset past the tolerance in its hop column is centered?: false" do
      hits =
        DungeonGraph.classify_hits(%{
          dungeon_graph_node_low_coin_all: [{1490, 654, 40, 20}]
        })

      assert [%{level: :low, hop: 2, centered?: false}] = hits
    end

    test "a coin whose center falls outside every hop column is dropped" do
      hits =
        DungeonGraph.classify_hits(%{
          dungeon_graph_node_high_coin_all: [{480, 16, 40, 20}]
        })

      assert hits == []
    end
  end

  describe "apply_hits_to_nodes/2" do
    test "tags nodes as battle/hard_battle from hits, leaves unmatched nodes as event" do
      nodes = %{
        {1, :mid} => %{hop: 1, level: :mid, type: :event},
        {2, :low} => %{hop: 2, level: :low, type: :event},
        {3, :high} => %{hop: 3, level: :high, type: :event}
      }

      hits = [
        %{level: :mid, hop: 1, hook: :dungeon_graph_node_mid_coin_some, rect: {0, 0, 1, 1}, centered?: true},
        %{level: :low, hop: 2, hook: :dungeon_graph_node_low_coin_all, rect: {0, 0, 1, 1}, centered?: false}
      ]

      classified = DungeonGraph.apply_hits_to_nodes(nodes, hits)

      assert classified[{1, :mid}].type == :battle
      assert classified[{2, :low}].type == :hard_battle
      assert classified[{3, :high}].type == :event
    end
  end
end
