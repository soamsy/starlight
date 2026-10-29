defmodule StarlightBot.GiftPlans.RouteDefaultsTest do
  use ExUnit.Case, async: false

  alias StarlightBot.GiftPlans.{RouteDefaults, Routes}
  alias StarlightBot.{BaseRepo, Repo}

  setup do
    :ok = StarlightBot.TestDB.checkout()
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
    assert Enum.map(RouteDefaults.get(2), &Map.delete(&1, "id")) == Enum.map(Routes.defaults(2), &Map.delete(&1, "id"))
  end

  test "saving a tier again replaces its default" do
    :ok = RouteDefaults.put(2, [Routes.new([2, 2, 2])])
    :ok = RouteDefaults.put(2, [Routes.new([2, 2, 1]), Routes.new([3, 2, 1])])

    assert Enum.map(RouteDefaults.all()[2], & &1["combo"]) == [[2, 2, 1], [3, 2, 1]]
  end

  test "shipped templates fill in for tiers the user has not saved, and a saved default wins over them" do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    template = Jason.encode!([Routes.new([2, 2, 1], buy_up_to: 2)])
    BaseRepo.query!("INSERT INTO fusion_route_templates (tier, routes, updated_at) VALUES (3, ?, ?)", [template, now])

    assert Enum.map(RouteDefaults.get(3), & &1["combo"]) == [[2, 2, 1]]
    assert Enum.map(RouteDefaults.all()[3], & &1["combo"]) == [[2, 2, 1]]

    :ok = RouteDefaults.put(3, [Routes.new([3, 3, 1])])
    assert Enum.map(RouteDefaults.get(3), & &1["combo"]) == [[3, 3, 1]]
  end
end
