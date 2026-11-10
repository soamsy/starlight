defmodule StarlightBot.GiftPlans.RefreshCostsTest do
  use ExUnit.Case, async: true

  alias StarlightBot.GiftPlans.RefreshCosts

  defp refresh_case(action, max), do: %{"action" => action, "max" => max}

  test "free refreshes come from the picked graces" do
    assert RefreshCosts.free([]) == {0, 0}
    assert RefreshCosts.free([%{"index" => 0, "enhance" => 0}]) == {1, 0}
    assert RefreshCosts.free([%{"index" => 0, "enhance" => 2}, %{"index" => 5, "enhance" => 1}]) == {2, 1}
    assert RefreshCosts.free([%{"index" => 5, "enhance" => 2}, %{"index" => 3, "enhance" => 2}]) == {0, 2}
  end

  test "columns add up the case limits, cap at 15 and ignore leave" do
    assert RefreshCosts.columns([refresh_case("refresh", 2), refresh_case("affinity_refresh", 4), refresh_case("leave", 9)]) == 6
    assert RefreshCosts.columns([refresh_case("refresh", nil)]) == 15
    assert RefreshCosts.columns([refresh_case("refresh", 12), refresh_case("affinity_refresh", 12)]) == 15
    assert RefreshCosts.columns([refresh_case("leave", nil)]) == 0
  end

  test "default path follows case order" do
    cases = [refresh_case("refresh", 2), refresh_case("affinity_refresh", 1)]
    assert RefreshCosts.default_path(cases) == [:normal, :normal, :keyword]
  end

  test "costs rise by 15 per refresh and a used free refresh still counts" do
    cells = RefreshCosts.grid([:normal], {1, 0}, 3)
    assert [%{normal: {0, true}, keyword: {90, false}}, %{normal: {30, false}, keyword: {105, false}}, %{normal: {45, false}}] = cells
    assert [%{total: 0}, %{total: nil}, %{total: nil}] = cells
  end

  test "totals accumulate along the chosen path" do
    cells = RefreshCosts.grid([:normal, :keyword, :normal], {0, 0}, 3)
    assert Enum.map(cells, & &1.total) == [15, 120, 165]
  end

  test "the free normal refresh saves most on a later slot" do
    assert RefreshCosts.total([:normal, :keyword], {1, 0}) == 105
    assert RefreshCosts.total([:keyword, :normal], {1, 0}) == 90
    assert RefreshCosts.cheapest([:normal, :keyword], {1, 0}) == {90, [:keyword, :normal]}
  end

  test "cheapest handles an empty path" do
    assert RefreshCosts.cheapest([], {1, 1}) == {0, []}
  end
end
