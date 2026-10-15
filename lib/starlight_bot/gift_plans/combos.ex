defmodule StarlightBot.GiftPlans.Combos do
  @points %{1 => 3, 2 => 6, 3 => 10, 4 => 15}
  @max_ingredients %{normal: 3, super: 5}
  @tier_ceilings %{normal: [{10, 1}, {16, 2}, {24, 3}], super: [{9, 1}, {14, 2}, {21, 3}]}
  @shops [:normal, :super]

  def points(combo), do: combo |> Enum.map(&Map.fetch!(@points, &1)) |> Enum.sum()

  def tier_for(points, shop) do
    Enum.find_value(@tier_ceilings[shop], 4, fn {ceiling, tier} -> if points <= ceiling, do: tier end)
  end

  def keyword_odds(combo) when length(combo) == 2, do: 60
  def keyword_odds(combo) when length(combo) == 3, do: 90
  def keyword_odds(_combo), do: 99

  def allowed?(combo, target_tier, shop) do
    length(combo) >= 2 and length(combo) <= @max_ingredients[shop] and tier_for(points(combo), shop) == target_tier
  end

  def shops(combo, target_tier), do: Enum.filter(@shops, &allowed?(combo, target_tier, &1))

  def valid_combos(target_tier) do
    2..@max_ingredients.super
    |> Enum.flat_map(&multisets(&1, [4, 3, 2, 1]))
    |> Enum.filter(fn combo -> Enum.any?(@shops, &minimal?(combo, target_tier, &1)) end)
    |> Enum.map(&%{combo: &1, points: points(&1), shops: shops(&1, target_tier)})
    |> Enum.sort_by(&{shop_rank(&1.shops), length(&1.combo), -&1.points})
  end

  defp minimal?(combo, target_tier, shop) do
    rest = combo |> Enum.sort() |> tl()
    allowed?(combo, target_tier, shop) and (length(rest) < 2 or tier_for(points(rest), shop) < target_tier)
  end

  defp shop_rank([:normal, :super]), do: 0
  defp shop_rank([:normal]), do: 1
  defp shop_rank([:super]), do: 2

  defp multisets(0, _tiers), do: [[]]
  defp multisets(_n, []), do: []

  defp multisets(n, [tier | rest] = tiers) do
    Enum.map(multisets(n - 1, tiers), &[tier | &1]) ++ multisets(n, rest)
  end

  def combo_key(combo), do: Enum.join(combo, "-")

  def parse_combo_key(key), do: key |> String.split("-") |> Enum.map(&String.to_integer/1)
end
