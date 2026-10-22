defmodule StarlightBot.Automation.DungeonPathPlannerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.DungeonPathPlanner
  alias StarlightBot.Vision.DungeonGraph

  defp graph(types, links) do
    %DungeonGraph{
      current_level: :mid,
      nodes: Map.new(types, fn {{hop, level} = key, type} -> {key, %{hop: hop, level: level, type: type}} end),
      edges: Enum.map(links, fn {from, to} -> %{from_node: from, to_node: to, variant: nil} end),
      diagnostics: [],
      warnings: [],
      node_hits: [],
      warning_hits: []
    }
  end

  defp floor_2_graph do
    graph(
      %{
        {0, :mid} => :event,
        {1, :high} => :battle,
        {1, :mid} => :battle,
        {1, :low} => :battle,
        {2, :high} => :event,
        {2, :mid} => :battle,
        {2, :low} => :risky_battle,
        {3, :high} => :battle,
        {3, :low} => :event
      },
      [
        {{0, :mid}, {1, :high}},
        {{0, :mid}, {1, :low}},
        {{0, :mid}, {1, :mid}},
        {{1, :high}, {2, :high}},
        {{1, :low}, {2, :low}},
        {{1, :low}, {2, :mid}},
        {{1, :mid}, {2, :high}},
        {{1, :mid}, {2, :mid}},
        {{2, :high}, {3, :high}},
        {{2, :low}, {3, :low}},
        {{2, :mid}, {3, :high}},
        {{2, :mid}, {3, :low}}
      ]
    )
  end

  defp steps({:ok, path}), do: Enum.map(path, & &1.to_node)

  test "on equal full-path cost, prefers the step that keeps more cheapest paths open" do
    assert {:ok, %{to_node: {1, :mid}}} = DungeonPathPlanner.choose_target(floor_2_graph())
  end

  test "planned_path covers every visible hop and applies the same tie-break downstream" do
    assert steps(DungeonPathPlanner.planned_path(floor_2_graph())) == [{1, :mid}, {2, :mid}, {3, :low}]
  end

  test "a cheaper full path beats optionality" do
    g =
      graph(
        %{{1, :high} => :event, {1, :mid} => :battle, {2, :high} => :event, {2, :mid} => :battle, {2, :low} => :battle},
        [
          {{0, :mid}, {1, :high}},
          {{0, :mid}, {1, :mid}},
          {{1, :high}, {2, :high}},
          {{1, :mid}, {2, :mid}},
          {{1, :mid}, {2, :low}}
        ]
      )

    assert {:ok, %{to_node: {1, :high}}} = DungeonPathPlanner.choose_target(g)
  end

  test "with equal cost and equal cheapest-path count, prefers more reachable nodes" do
    g =
      graph(
        %{{1, :high} => :battle, {1, :mid} => :battle, {2, :high} => :event, {2, :mid} => :battle},
        [
          {{0, :mid}, {1, :high}},
          {{0, :mid}, {1, :mid}},
          {{1, :high}, {2, :high}},
          {{1, :mid}, {2, :high}},
          {{1, :mid}, {2, :mid}}
        ]
      )

    assert {:ok, %{to_node: {1, :mid}}} = DungeonPathPlanner.choose_target(g)
  end

  defp hiccup_start_view do
    graph(
      %{
        {0, :mid} => :event,
        {1, :high} => :battle,
        {1, :mid} => :hard_battle,
        {1, :low} => :hard_battle,
        {2, :high} => :event,
        {2, :mid} => :battle,
        {3, :high} => :battle,
        {3, :mid} => :battle,
        {3, :low} => :event
      },
      [
        {{0, :mid}, {1, :high}},
        {{0, :mid}, {1, :mid}},
        {{0, :mid}, {1, :low}},
        {{1, :high}, {2, :high}},
        {{1, :high}, {2, :mid}},
        {{1, :mid}, {2, :mid}},
        {{1, :low}, {2, :mid}},
        {{2, :high}, {3, :high}},
        {{2, :high}, {3, :mid}},
        {{2, :mid}, {3, :mid}},
        {{2, :mid}, {3, :low}}
      ]
    )
  end

  defp hiccup_top_view do
    graph(
      %{
        {0, :mid} => :battle,
        {1, :mid} => :event,
        {1, :low} => :battle,
        {2, :mid} => :battle,
        {2, :low} => :battle,
        {3, :low} => :risky_battle
      },
      [
        {{0, :mid}, {1, :mid}},
        {{0, :mid}, {1, :low}},
        {{1, :mid}, {2, :mid}},
        {{1, :mid}, {2, :low}},
        {{1, :low}, {2, :low}},
        {{2, :mid}, {3, :low}},
        {{2, :low}, {3, :low}}
      ]
    )
  end

  test "without memory, the event that slid to the lowest row is lost and the planner walks into risky" do
    assert {:ok, %{to_node: {1, :mid}}} = DungeonPathPlanner.choose_target(hiccup_top_view())
  end

  test "the event remembered from the start view pulls the planner down toward it" do
    remembered = DungeonGraph.advance_view(hiccup_start_view(), :high)
    merged = DungeonGraph.merge_remembered(hiccup_top_view(), remembered)

    assert merged.nodes[{2, :lowest}].type == :event
    assert {:ok, %{to_node: {1, :low}}} = DungeonPathPlanner.choose_target(merged)
  end

  test "a path ending short of the horizon is charged a battle per unseen hop" do
    g =
      graph(
        %{{1, :high} => :event, {1, :mid} => :event, {2, :mid} => :event},
        [
          {{0, :mid}, {1, :high}},
          {{0, :mid}, {1, :mid}},
          {{1, :mid}, {2, :mid}}
        ]
      )

    assert {:ok, %{to_node: {1, :mid}}} = DungeonPathPlanner.choose_target(g)
  end
end
