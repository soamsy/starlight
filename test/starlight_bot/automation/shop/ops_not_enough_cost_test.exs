defmodule StarlightBot.Automation.Shop.OpsNotEnoughCostTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.Shop.Ops

  @regions [
    {:shop_not_enough_cost_0_0, {860, 317, 154, 38}},
    {:shop_not_enough_cost_0_1, {1094, 321, 148, 34}},
    {:shop_not_enough_cost_1_0, {860, 545, 149, 37}},
    {:shop_not_enough_cost_1_1, {1088, 538, 154, 46}}
  ]

  test "picks the nearest hook above the item center in the same column" do
    assert Ops.not_enough_cost_hook({937, 420}, @regions) == :shop_not_enough_cost_0_0
    assert Ops.not_enough_cost_hook({1165, 650}, @regions) == :shop_not_enough_cost_1_1
  end

  test "a hook overlapping the top of the item still counts as long as it ends above the center" do
    assert Ops.not_enough_cost_hook({937, 590}, @regions) == :shop_not_enough_cost_1_0
  end

  test "no hook above the item means nil" do
    assert Ops.not_enough_cost_hook({937, 300}, @regions) == nil
    assert Ops.not_enough_cost_hook({1700, 420}, @regions) == nil
  end
end
