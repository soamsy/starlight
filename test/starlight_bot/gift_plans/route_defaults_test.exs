defmodule StarlightBot.GiftPlans.RouteDefaultsTest do
  use ExUnit.Case, async: false

  alias StarlightBot.GiftPlans.{RouteDefaults, Routes}
  alias StarlightBot.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "a saved tier default comes back with fresh route ids, and unsaved tiers fall back to the built-in defaults" do
    routes = [Routes.new([3, 2, 2], buy_up_to: 3, subgoals: %{"2" => [Routes.new([1, 1, 1])]})]
    :ok = RouteDefaults.put(3, routes)

    [copy] = RouteDefaults.get(3)
    assert copy["combo"] == [3, 2, 2]
    assert copy["buy_up_to"] == 3
    assert copy["id"] != hd(routes)["id"]
    assert [%{"combo" => [1, 1, 1]}] = Routes.subgoals_for(copy, 2)

    Repo.query!("DELETE FROM fusion_route_defaults WHERE tier = 2")
    assert RouteDefaults.get(2) == Routes.defaults(2)
  end

  test "saving a tier again replaces its default" do
    :ok = RouteDefaults.put(2, [Routes.new([2, 2, 2])])
    :ok = RouteDefaults.put(2, [Routes.new([2, 2, 1]), Routes.new([3, 2, 1])])

    assert Enum.map(RouteDefaults.all()[2], & &1["combo"]) == [[2, 2, 1], [3, 2, 1]]
  end

  test "the migration seeds the tier 3 and tier 4 route sets the plans already share" do
    labels = fn tier -> Enum.map(RouteDefaults.get(tier), &Routes.label/1) end

    assert labels.(3) == ["2-2-2 (buy ≤T2)", "2-2-1 (buy ≤T2)", "3-2-1 (buy ≤T2)"]
    assert length(labels.(4)) == 6
    assert "3-3-2 (buy ≤T3, sub T3)" in labels.(4)
  end
end
