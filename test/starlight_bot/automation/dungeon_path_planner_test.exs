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
end
