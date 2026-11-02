defmodule StarlightBot.GiftPlans.FusionRouteTemplatesTest do
  use ExUnit.Case, async: false

  alias StarlightBot.GiftPlans.{FusionRouteTemplates, Routes}
  alias StarlightBot.{BaseRepo, Repo}

  setup do
    :ok = StarlightBot.TestDB.checkout()
    Repo.query!("DELETE FROM fusion_route_user_templates")
    BaseRepo.query!("DELETE FROM fusion_route_templates")
    :ok
  end

  defp base_template(tier, name, combo) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    BaseRepo.query!("INSERT INTO fusion_route_templates (tier, name, routes, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?)", [tier, name, Jason.encode!([Routes.new(combo)]), now, now])
  end

  test "a tier with no templates starts new fusions from the built-in routes" do
    assert Enum.map(FusionRouteTemplates.initial(2), & &1["combo"]) == Enum.map(Routes.defaults(2), & &1["combo"])
  end

  test "new fusions start from the first template of their tier, with fresh route ids" do
    base_template(3, "First", [2, 2, 1])
    base_template(3, "Second", [3, 3, 1])

    [route] = FusionRouteTemplates.initial(3)
    assert route["combo"] == [2, 2, 1]
    assert route["id"] != hd(hd(FusionRouteTemplates.list(3)).routes)["id"]
    assert Enum.map(FusionRouteTemplates.list(3), & &1.name) == ["First", "Second"]
  end

  test "templates are listed per tier and unfusable tiers have none" do
    base_template(4, "Four", [4, 2, 2])
    assert FusionRouteTemplates.list(3) == []
    assert FusionRouteTemplates.list(5) == []
    assert {:error, :tier_not_fusable} = FusionRouteTemplates.create(5, "Nope", [])
  end

  test "create rejects blank and duplicate names within a tier but allows the same name in another tier" do
    assert {:error, :blank_name} = FusionRouteTemplates.create(3, "  ", [])
    assert {:ok, ref} = FusionRouteTemplates.create(3, "Mine", [Routes.new([2, 2, 2])])
    assert {:error, :name_taken} = FusionRouteTemplates.create(3, "Mine", [])
    assert {:ok, _} = FusionRouteTemplates.create(4, "Mine", [])
    assert %{name: "Mine", tier: 3, routes: [%{"combo" => [2, 2, 2]}]} = FusionRouteTemplates.get(ref)
  end

  test "delete removes a template and rejects unknown refs" do
    {:ok, ref} = FusionRouteTemplates.create(3, "Gone", [])
    assert :ok = FusionRouteTemplates.delete(ref)
    assert FusionRouteTemplates.get(ref) == nil
    assert {:error, :not_deletable} = FusionRouteTemplates.delete(ref)
    assert {:error, :not_deletable} = FusionRouteTemplates.delete("junk")
  end

  test "user templates are listed after shipped ones" do
    base_template(3, "Shipped", [2, 2, 1])
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    Repo.query!("INSERT INTO fusion_route_user_templates (tier, name, routes, inserted_at, updated_at) VALUES (3, 'Mine', '[]', ?, ?)", [now, now])

    assert [%{name: "Shipped", source: :base}, %{name: "Mine", source: :user, deletable: true}] = FusionRouteTemplates.list(3)
  end
end
