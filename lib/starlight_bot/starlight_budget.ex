defmodule StarlightBot.StarlightBudget do
  alias StarlightBot.ThemePackPlans.Resolver

  @base 60
  @floors 1..5
  @max_sinner_bonus 60
  @rest_mult_per_point_milli 17
  @max_rest_mult_milli 2000
  @railway_bonus 5
  @railway_prefix "Line"
  @first_pack_search_cost 20
  @pack_search_cost_step 10
  @max_reward_cards 5
  @starlight_per_card 8

  def base, do: @base
  def max_sinner_bonus, do: @max_sinner_bonus
  def railway_bonus, do: @railway_bonus
  def max_reward_cards, do: @max_reward_cards

  def floor_reward(floor, "hard"), do: 4 * min(floor, 5)
  def floor_reward(floor, _mode), do: min(floor, 5)

  def floor_rewards(mode_schedule) do
    for floor <- @floors do
      mode = Resolver.mode_for_floor(mode_schedule, floor)
      %{floor: floor, mode: mode, starlight: floor_reward(floor, mode)}
    end
  end

  def rest_multiplier_milli(rest_bonus), do: min(1000 + @rest_mult_per_point_milli * rest_bonus, @max_rest_mult_milli)

  def exploration_gain(floor_total, railway_packs, rest_bonus) do
    div((floor_total + @railway_bonus * railway_packs) * rest_multiplier_milli(rest_bonus), 1000)
  end

  def pack_search_cost(searches), do: @first_pack_search_cost * searches + div(@pack_search_cost_step * searches * (searches - 1), 2)

  def max_pack_searches(plan_data), do: Enum.count(plan_data["search_floors"] || [], &(&1 in @floors))

  def railway_pack?(pack), do: String.starts_with?(pack.name_en, @railway_prefix)

  def railway_floors(plan_data, theme_packs, priorities) do
    railway = Enum.filter(theme_packs, &railway_pack?/1)
    schedule = plan_data["mode_schedule"] || []

    Enum.filter(@floors, fn floor ->
      mode = Resolver.mode_for_floor(schedule, floor)

      Enum.any?(railway, fn pack ->
        floor in Resolver.eligible_floors(pack, mode) and Resolver.priority_at(plan_data, pack, mode, floor) in priorities
      end)
    end)
  end

  def cards_gain(reward_cards), do: @starlight_per_card * reward_cards
end
