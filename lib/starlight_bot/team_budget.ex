defmodule StarlightBot.TeamBudget do
  alias StarlightBot.{BattlePlans, GiftPlans, Plans, StarlightBudget, ThemePacks}
  alias StarlightBot.PackPlans.{Odds, Resolver}
  alias StarlightBotWeb.Live.GiftPlanEditorLive

  def sources, do: %{gift_plans: Plans.list(:gift_plans), pack_plans: Plans.list(:pack_plans), theme_packs: ThemePacks.list_theme_packs()}

  def for_team(team, rest_bonus, opts \\ [], sources \\ sources()) do
    build(sources.gift_plans, sources.pack_plans, sources.theme_packs, selected_ids(team), rest_bonus, opts)
  end

  def free_sinners(%{free_sinners: free_sinners}) when is_integer(free_sinners), do: free_sinners
  def free_sinners(team), do: StarlightBudget.default_free_sinners(first_lineup_size(team))

  def net_at(budget, rest_bonus) do
    exploration = StarlightBudget.exploration_gain(budget.floor_total, budget.railway_packs, rest_bonus)
    budget.net - budget.income.sinner_bonus - budget.income.exploration + rest_bonus + exploration
  end

  def selected_ids(team) do
    %{
      "gift_plan" => team.gift_plan_id,
      "battle_plan" => team.battle_plan_id,
      "pack_plan" => team.pack_plan_id,
      "gift_override" => template_override(team, :gift_plans),
      "pack_override" => template_override(team, :pack_plans)
    }
  end

  defp template_override(team, table) do
    case Plans.for_team(team, table) do
      %{template_id: template_id, data: data} when is_integer(template_id) -> data
      _ -> nil
    end
  end

  def first_lineup_size(nil), do: 0

  def first_lineup_size(team) do
    case Plans.for_team(team, :battle_plans) do
      %{data: data} -> length((data |> BattlePlans.lineups() |> List.first() || %{})["sinners"] || [])
      _ -> 0
    end
  end

  def build(gift_plans, pack_plans, theme_packs, selected_ids, rest_bonus, opts \\ []) do
    gift_data = selected_ids["gift_override"] || plan_data_for(gift_plans, selected_ids["gift_plan"])
    plan_data =
      (selected_ids["pack_override"] || plan_data_for(pack_plans, selected_ids["pack_plan"]))
      |> Resolver.with_mode_override(Keyword.get(opts, :mode, "default"))
      |> Resolver.with_search_override(Keyword.get(opts, :search, "default"))
    floors = StarlightBudget.floor_rewards(plan_data["mode_schedule"] || [])
    floor_total = floors |> Enum.map(& &1.starlight) |> Enum.sum()
    max_pack_searches = StarlightBudget.max_pack_searches(plan_data)
    schedule = plan_data["mode_schedule"] || []
    floor_modes = Enum.map(1..5, &{&1, Resolver.mode_for_floor(schedule, &1)})
    plannable = Enum.filter(theme_packs, &ThemePacks.plannable?/1)
    run = Odds.run(plan_data, plannable, floor_modes, gift_data["grace_picks"] || [])
    run_odds = run.floors
    railway_by_floor = Map.new(run_odds, fn {floor, odds} -> {floor, odds.railway} end)
    railway_packs = railway_by_floor |> Map.values() |> Enum.sum()
    gift_searches = length(gift_data["gift_search"] || [])
    order_for = encounter_order_for(gift_data)
    continuing? = Resolver.extreme?(plan_data)

    encounter_floors =
      for floor <- 1..5 do
        screens = StarlightBudget.encounter_screens(floor, run_odds[floor].floating, continuing?)
        order = order_for.(floor)
        chance = StarlightBudget.starlight_pick_chance(order)
        position = Enum.find_index(order, &(&1 == "starlight"))
        %{floor: floor, floating: run_odds[floor].floating, screens: screens, position: position && position + 1, chance: chance, starlight: screens.total * chance * StarlightBudget.starlight_reward_mean()}
      end

    encounter_starlight = encounter_floors |> Enum.map(& &1.starlight) |> Enum.sum()

    income = %{
      base: StarlightBudget.base(),
      sinner_bonus: rest_bonus,
      exploration: StarlightBudget.exploration_gain(floor_total, railway_packs, rest_bonus),
      encounters: round(encounter_starlight)
    }

    costs = %{
      grace: if(gift_data == %{}, do: 0, else: GiftPlanEditorLive.grace_total_cost(GiftPlans.normalize(gift_data))),
      gift_search: GiftPlans.gift_search_starlight_cost(gift_searches),
      pack_search: round(Odds.expected_search_cost(run.searches))
    }

    %{
      income: income,
      costs: costs,
      floors: floors,
      floor_total: floor_total,
      railway_packs: railway_packs,
      railway_by_floor: railway_by_floor,
      rest_multiplier: StarlightBudget.rest_multiplier_milli(rest_bonus) / 1000,
      encounter_floors: encounter_floors,
      encounter_screens: encounter_floors |> Enum.map(& &1.screens.total) |> Enum.sum(),
      encounter_pulls: encounter_floors |> Enum.map(&(&1.screens.total * &1.chance)) |> Enum.sum(),
      encounter_starlight: encounter_starlight,
      graces: picked_graces(gift_data),
      gift_searches: gift_searches,
      gift_search_names: gift_data["gift_search"] || [],
      pack_searches: Odds.expected_searches(run.searches),
      search_by_floor: Map.new(run_odds, fn {floor, odds} -> {floor, odds.search} end),
      search_counts: run.searches,
      search_floors: Enum.filter(plan_data["search_floors"] || [], &(&1 in 1..5)) |> Enum.sort(),
      search_average_cost: Odds.expected_search_cost(run.searches),
      max_pack_searches: max_pack_searches,
      has_gift_plan?: gift_data != %{},
      has_pack_plan?: plan_data != %{},
      net: Enum.sum(Map.values(income)) - Enum.sum(Map.values(costs))
    }
  end

  defp picked_graces(gift_data) do
    for pick <- gift_data["grace_picks"] || [],
        grace <- [Enum.find(GiftPlanEditorLive.graces(), &(&1.index == pick["index"]))],
        grace != nil do
      %{index: grace.index, title: "#{grace.name} #{GiftPlanEditorLive.grace_enhance_icon(pick["enhance"] || 0)}"}
    end
  end

  defp encounter_order_for(gift_data) when gift_data == %{}, do: fn _floor -> GiftPlans.encounter_reward_default_order() end

  defp encounter_order_for(gift_data) do
    normalized = GiftPlans.normalize(gift_data)
    &GiftPlans.encounter_reward_order(normalized, &1)
  end

  defp plan_data_for(plans, id), do: Enum.find_value(plans, %{}, &(&1.id == id && &1.data)) || %{}
end
