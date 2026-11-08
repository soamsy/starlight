defmodule StarlightBot.StarlightBudget do
  alias StarlightBot.PackPlans.Resolver

  @base 60
  @floors 1..5
  @max_free_sinners 12
  @rest_per_free_sinner 5
  @max_deployed 7
  @rest_mult_per_point_milli 17
  @max_rest_mult_milli 2000
  @railway_bonus 5
  @railway_prefix "Line"
  @first_pack_search_cost 20
  @pack_search_cost_step 10
  @reward_layout_size 3
  @reward_option_count 5
  @starlight_reward_range 8..14
  @regular_chance %{1 => 0.075, 2 => 0.10, 3 => 0.10, 4 => 0.125}
  @focused_chance %{1 => 0.0, 2 => 0.20, 3 => 0.20, 4 => 0.25}
  @late_regular_chance 0.125
  @late_focused_chance 0.25
  @focused_share 1 / 3

  def base, do: @base

  def format(value), do: value |> round() |> Integer.to_string()

  def signed(value) do
    text = format(value)
    if String.starts_with?(text, "-"), do: text, else: "+" <> text
  end
  def max_free_sinners, do: @max_free_sinners
  def rest_per_free_sinner, do: @rest_per_free_sinner
  def rest_bonus(free_sinners), do: @rest_per_free_sinner * free_sinners
  def default_free_sinners(locked_count), do: @max_free_sinners - min(locked_count, @max_deployed)
  def railway_bonus, do: @railway_bonus

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
    trunc((floor_total + @railway_bonus * railway_packs) * rest_multiplier_milli(rest_bonus) / 1000)
  end

  def pack_search_cost(searches), do: @first_pack_search_cost * searches + div(@pack_search_cost_step * searches * (searches - 1), 2)

  def max_pack_searches(plan_data), do: Enum.count(plan_data["search_floors"] || [], &(&1 in @floors))

  def railway_pack?(pack), do: String.starts_with?(pack.name_en, @railway_prefix)

  def starlight_reward_mean, do: (@starlight_reward_range.first + @starlight_reward_range.last) / 2

  def starlight_pick_chance(order) do
    case Enum.find_index(order, &(&1 == "starlight")) do
      nil -> 0.0
      index -> layouts_where_starlight_wins(@reward_option_count - 1 - index) / binomial(@reward_option_count, @reward_layout_size)
    end
  end

  def encounter_screens(floor, floating, continuing?) do
    {regular_nodes, focused_nodes} = if floor == 1, do: {floating, 0.0}, else: {floating * (1 - @focused_share), floating * @focused_share}
    boss = if floor < 5 or continuing?, do: 1.0, else: 0.0
    regular = regular_nodes * Map.get(@regular_chance, floor, @late_regular_chance)
    focused = focused_nodes * Map.get(@focused_chance, floor, @late_focused_chance)
    %{boss: boss, regular: regular, focused: focused, total: boss + regular + focused}
  end

  defp layouts_where_starlight_wins(lower_options) when lower_options >= @reward_layout_size - 1, do: binomial(lower_options, @reward_layout_size - 1)
  defp layouts_where_starlight_wins(_lower_options), do: 0

  defp binomial(n, k), do: Enum.reduce(1..k//1, 1, fn i, acc -> div(acc * (n - k + i), i) end)
end
