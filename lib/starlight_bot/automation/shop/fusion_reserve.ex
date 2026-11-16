defmodule StarlightBot.Automation.Shop.FusionReserve do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.GiftPlans
  alias StarlightBot.GiftPlans.{FusionPlanner, Routes}

  def counts(progress, keep, state, ctx) do
    inventory = RunMemory.ego_gifts(ctx)
    fodder = GiftPlans.fodder(inventory, keep, state.gifts_by_id)
    fusing = Enum.filter(progress.entries, &(&1.fuse and is_binary(&1.gift)))

    fixed = for entry <- fusing, GiftPlans.fixed_fusion?(entry), pending?(progress, entry, inventory, state), id <- fixed_ids(entry, inventory, state), do: id
    tiered = for entry <- fusing, GiftPlans.tiered_fusion?(entry), GiftPlans.needed?(progress, entry), id <- tiered_ids(entry, fodder, state), do: id

    Enum.frequencies(fixed ++ tiered)
  end

  defp pending?(progress, entry, inventory, state) do
    GiftPlans.needed?(progress, entry) or
      (entry.goal == "optional" and GiftPlans.status(progress, entry) != :done and not owned?(inventory, state.gifts_by_name[entry.gift]))
  end

  defp owned?(_inventory, nil), do: false
  defp owned?(inventory, target), do: Map.has_key?(inventory, target.id)

  defp fixed_ids(entry, inventory, state) do
    case state.gifts_by_name[entry.gift] do
      nil ->
        []

      target ->
        recipe = GiftPlans.recipe_ids(target)
        fragments = for name <- GiftPlans.sin_fragments(), gift = state.gifts_by_name[name], gift.id not in recipe, Map.has_key?(inventory, gift.id), do: gift.id
        Enum.filter(recipe, &Map.has_key?(inventory, &1)) ++ Enum.take(fragments, GiftPlans.fragment_slots(target))
    end
  end

  defp tiered_ids(entry, fodder, state) do
    case state.gifts_by_name[entry.gift] do
      %{tier: tier} when is_integer(tier) ->
        counts = FusionPlanner.tier_counts(fodder)

        entry.fusion["routes"]
        |> demand(tier, counts, state.shop_type)
        |> Enum.flat_map(fn {demand_tier, n} ->
          fodder |> Enum.filter(&(&1.tier == demand_tier)) |> Enum.sort_by(&{&1.uptie, &1.selling_cost, &1.name}) |> Enum.take(n) |> Enum.map(& &1.id)
        end)

      _ ->
        []
    end
  end

  defp demand(routes, tier, counts, shop) do
    routes
    |> Enum.filter(&FusionPlanner.reachable?(&1, tier, counts, shop))
    |> Enum.map(&route_demand(&1, counts, shop))
    |> Enum.max_by(&(&1 |> Map.values() |> Enum.sum()), fn -> %{} end)
  end

  defp route_demand(route, counts, shop) do
    route
    |> FusionPlanner.shortfall(counts)
    |> Map.keys()
    |> Enum.reduce(FusionPlanner.shortfall(route, %{}), fn short_tier, acc ->
      Map.merge(acc, demand(Routes.subgoals_for(route, short_tier), short_tier, counts, shop), fn _tier, a, b -> max(a, b) end)
    end)
  end
end
