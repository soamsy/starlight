defmodule StarlightBot.GiftPlans.FusionPlannerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.GiftPlans.{FusionPlanner, Routes}

  defp routes_332 do
    [Routes.new([3, 3, 2], buy_up_to: 3, subgoals: %{"3" => [Routes.new([2, 2, 2], leftover: %{"2" => 1})]}), Routes.new([4, 2, 2])]
  end

  defp gift(id, tier, opts \\ []) do
    %{id: id, name: id, tier: tier, uptie: Keyword.get(opts, :uptie, 0), selling_cost: Keyword.get(opts, :sell, 50)}
  end

  test "current_fusion/2 picks the first definition whose target isn't owned" do
    defs = [%{"target" => "A"}, %{"target" => "B"}, %{"target" => "C"}]
    assert FusionPlanner.current_fusion(defs, MapSet.new(["A"]))["target"] == "B"
    assert FusionPlanner.current_fusion(defs, MapSet.new(["A", "B", "C"])) == nil
  end

  test "shortfall/2 adds leftover to the combo's needs" do
    route = Routes.new([2, 2, 2], leftover: %{"2" => 1})
    assert FusionPlanner.shortfall(route, %{2 => 2}) == %{2 => 2}
    assert FusionPlanner.shortfall(route, %{2 => 4}) == %{}
  end

  describe "reachable?/4" do
    test "a route needing a tier it can't buy or sub-goal is unreachable until that tier is owned" do
      route = Routes.new([4, 2, 2], buy_up_to: 3)
      refute FusionPlanner.reachable?(route, 4, %{}, :normal)
      assert FusionPlanner.reachable?(route, 4, %{4 => 1}, :normal)
    end

    test "a sub-goal makes a short tier reachable, recursively" do
      top = Routes.new([3, 3, 2], buy_up_to: 2, subgoals: %{"3" => [Routes.new([2, 2, 2], buy_up_to: 2)]})
      assert FusionPlanner.reachable?(top, 4, %{}, :normal)

      [stuck, _] = routes_332()
      refute FusionPlanner.reachable?(%{stuck | "buy_up_to" => 2}, 4, %{}, :normal)
      assert FusionPlanner.reachable?(%{stuck | "buy_up_to" => 2}, 4, %{2 => 4}, :normal)
    end

    test "super-only combos are never reachable in a normal shop" do
      route = Routes.new([3, 2, 2], buy_up_to: 3)
      refute FusionPlanner.reachable?(route, 4, %{3 => 1, 2 => 2}, :normal)
      assert FusionPlanner.reachable?(route, 4, %{3 => 1, 2 => 2}, :super)
    end
  end

  describe "next_fusion/4" do
    test "fuses the top route when every ingredient is owned" do
      assert FusionPlanner.next_fusion(routes_332(), 4, %{3 => 2, 2 => 1}, :normal) == {:fuse, 4, [3, 3, 2]}
    end

    test "works a sub-goal when the top route is short" do
      assert FusionPlanner.next_fusion(routes_332(), 4, %{3 => 1, 2 => 4}, :normal) == {:fuse, 3, [2, 2, 2]}
    end

    test "respects sub-goal leftovers" do
      assert FusionPlanner.next_fusion(routes_332(), 4, %{3 => 1, 2 => 3}, :normal) == nil
    end

    test "falls through to a later route" do
      assert FusionPlanner.next_fusion(routes_332(), 4, %{4 => 1, 2 => 2}, :normal) == {:fuse, 4, [4, 2, 2]}
    end
  end

  describe "wanted_tiers/4" do
    test "collects buyable short tiers from every reachable route and its sub-goals" do
      routes = [
        Routes.new([3, 3, 2], buy_up_to: 3, subgoals: %{"3" => [Routes.new([2, 2, 2], buy_up_to: 2)]}),
        Routes.new([4, 2, 2], buy_up_to: 2)
      ]

      assert FusionPlanner.wanted_tiers(routes, 4, %{}, :normal) == MapSet.new([2, 3])
      assert FusionPlanner.wanted_tiers(routes, 4, %{4 => 1}, :normal) == MapSet.new([2, 3])
    end

    test "unreachable routes want nothing" do
      assert FusionPlanner.wanted_tiers([Routes.new([4, 2, 2], buy_up_to: 3)], 4, %{}, :normal) == MapSet.new()
    end
  end

  test "pick_fodder/2 prefers un-uptied and cheaper gifts" do
    fodder = [gift("a", 2, uptie: 1), gift("b", 2, sell: 90), gift("c", 2, sell: 60), gift("d", 3)]
    assert {:ok, picks} = FusionPlanner.pick_fodder(fodder, [3, 2, 2])
    assert Enum.map(picks, & &1.id) |> Enum.sort() == ["b", "c", "d"]
    assert FusionPlanner.pick_fodder(fodder, [3, 3, 2]) == :error
  end
end
