defmodule StarlightBot.GiftPlans.RoutesTest do
  use ExUnit.Case, async: true

  alias StarlightBot.GiftPlans.Routes

  test "T4 defaults encode the 4-T2 rule as a T3 sub-goal needing one leftover T2" do
    [three_three_two, four_two_two] = Routes.defaults(4)

    assert three_three_two["combo"] == [3, 3, 2]
    assert three_three_two["buy_up_to"] == 3
    assert [%{"combo" => [2, 2, 2], "leftover" => %{"2" => 1}}] = Routes.subgoals_for(three_three_two, 3)
    assert four_two_two["buy_up_to"] == nil
  end

  test "subgoal_tiers/1 lists fusable ingredient tiers, highest first" do
    assert Routes.subgoal_tiers([3, 3, 2]) == [3, 2]
    assert Routes.subgoal_tiers([3, 2, 1, 1]) == [3, 2]
  end

  test "valid_for_tier/2 and invalid_count/2 check combos at every depth" do
    bad_sub = Routes.new([4, 4])
    routes = [Routes.new([3, 3, 2], subgoals: %{"3" => [bad_sub]}), Routes.new([2, 2, 2])]

    assert Enum.map(Routes.valid_for_tier(routes, 4), & &1["combo"]) == [[3, 3, 2]]
    assert Routes.invalid_count(routes, 4) == 2
  end

  test "label/1 summarizes customizations" do
    route = Routes.new([3, 3, 2], buy_up_to: 2, leftover: %{"2" => 1}, subgoals: %{"3" => [Routes.new([2, 2, 2])], "2" => []})
    assert Routes.label(route) == "3-3-2 (buy ≤T2, leave 1×T2, sub T3)"
  end
end
