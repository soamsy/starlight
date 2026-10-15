defmodule StarlightBot.GiftPlans.FusionPlanner do
  alias StarlightBot.GiftPlans.{Combos, Routes}

  def current_fusion(definitions, owned_names) do
    Enum.find(definitions, &(not MapSet.member?(owned_names, &1["target"])))
  end

  def tier_counts(fodder), do: Enum.frequencies_by(fodder, & &1.tier)

  def reachable?(route, tier, counts, shop) do
    Combos.allowed?(route["combo"], tier, shop) and
      Enum.all?(shortfall(route, counts), fn {short_tier, _n} ->
        buys?(route, short_tier) or Enum.any?(Routes.subgoals_for(route, short_tier), &reachable?(&1, short_tier, counts, shop))
      end)
  end

  def shortfall(route, counts) do
    leftover = Map.new(route["leftover"] || %{}, fn {tier, n} -> {to_int(tier), n} end)

    route["combo"]
    |> Enum.frequencies()
    |> Map.merge(leftover, fn _tier, a, b -> a + b end)
    |> Enum.map(fn {tier, n} -> {tier, n - Map.get(counts, tier, 0)} end)
    |> Enum.filter(fn {_tier, n} -> n > 0 end)
    |> Map.new()
  end

  def next_fusion(routes, tier, counts, shop) do
    routes
    |> Enum.filter(&reachable?(&1, tier, counts, shop))
    |> Enum.find_value(fn route ->
      short = shortfall(route, counts)

      if map_size(short) == 0 do
        {:fuse, tier, route["combo"]}
      else
        short
        |> Map.keys()
        |> Enum.sort(:desc)
        |> Enum.find_value(&next_fusion(Routes.subgoals_for(route, &1), &1, counts, shop))
      end
    end)
  end

  def wanted_tiers(routes, tier, counts, shop) do
    routes
    |> Enum.filter(&reachable?(&1, tier, counts, shop))
    |> Enum.reduce(MapSet.new(), fn route, acc ->
      Enum.reduce(shortfall(route, counts), acc, fn {short_tier, _n}, inner ->
        inner = if buys?(route, short_tier), do: MapSet.put(inner, short_tier), else: inner
        MapSet.union(inner, wanted_tiers(Routes.subgoals_for(route, short_tier), short_tier, counts, shop))
      end)
    end)
  end

  def pick_fodder(fodder, combo) do
    combo
    |> Enum.frequencies()
    |> Enum.reduce_while({:ok, []}, fn {tier, n}, {:ok, acc} ->
      picks = fodder |> Enum.filter(&(&1.tier == tier)) |> Enum.sort_by(&{&1.uptie, &1.selling_cost, &1.name}) |> Enum.take(n)
      if length(picks) == n, do: {:cont, {:ok, acc ++ picks}}, else: {:halt, :error}
    end)
  end

  defp buys?(route, tier), do: is_integer(route["buy_up_to"]) and tier <= route["buy_up_to"]

  defp to_int(tier) when is_integer(tier), do: tier
  defp to_int(tier), do: String.to_integer(tier)
end
