defmodule StarlightBot.StarlightBudgetTest do
  use ExUnit.Case, async: true

  alias StarlightBot.StarlightBudget

  defp gross(first_hard_floor, rest, railway) do
    schedule = if first_hard_floor, do: [%{"from_floor" => first_hard_floor, "mode" => "hard"}], else: []
    floors = schedule |> StarlightBudget.floor_rewards() |> Enum.map(& &1.starlight) |> Enum.sum()
    StarlightBudget.base() + rest + StarlightBudget.exploration_gain(floors, railway, rest)
  end

  test "floor_reward/2 pays the floor number, four times over on hard, capped at floor 5" do
    assert Enum.map(1..5, &StarlightBudget.floor_reward(&1, "normal")) == [1, 2, 3, 4, 5]
    assert Enum.map(1..5, &StarlightBudget.floor_reward(&1, "hard")) == [4, 8, 12, 16, 20]
    assert StarlightBudget.floor_reward(7, "hard") == 20
  end

  test "floor_rewards/1 follows the mode schedule across floors 1 to 5" do
    schedule = [%{"from_floor" => 1, "mode" => "normal"}, %{"from_floor" => 4, "mode" => "hard"}]
    rewards = StarlightBudget.floor_rewards(schedule)

    assert Enum.map(rewards, & &1.mode) == ~w(normal normal normal hard hard)
    assert rewards |> Enum.map(& &1.starlight) |> Enum.sum() == 1 + 2 + 3 + 16 + 20
  end

  test "gross gain matches the Borderlined MD6 starlight table" do
    assert gross(nil, 0, 0) == 75
    assert gross(nil, 60, 0) == 150
    assert gross(5, 12, 1) == 114
    assert gross(4, 24, 2) == 157
    assert gross(4, 25, 2) == 159
    assert gross(1, 48, 1) == 226
    assert gross(1, 60, 2) == 260
  end

  test "rest_multiplier_milli/1 caps at 2x" do
    assert StarlightBudget.rest_multiplier_milli(0) == 1000
    assert StarlightBudget.rest_multiplier_milli(24) == 1408
    assert StarlightBudget.rest_multiplier_milli(60) == 2000
  end

  test "pack_search_cost/1 rises by 10 per search across the run" do
    assert Enum.map(0..4, &StarlightBudget.pack_search_cost/1) == [0, 20, 50, 90, 140]
  end

  test "max_pack_searches/1 counts search floors inside the run" do
    assert StarlightBudget.max_pack_searches(%{"search_floors" => [1, 2, 3, 4, 5]}) == 5
    assert StarlightBudget.max_pack_searches(%{"search_floors" => [4, 5, 9]}) == 2
    assert StarlightBudget.max_pack_searches(%{}) == 0
  end

  test "starlight_pick_chance/1 counts the 3-of-5 layouts where starlight is the best option" do
    order = ~w(gain_cost random_gift starlight cost_plus_gift resources)
    chance = fn position -> StarlightBudget.starlight_pick_chance(List.insert_at(List.delete(order, "starlight"), position, "starlight")) end
    assert Enum.map(0..4, chance) == [0.6, 0.3, 0.1, 0.0, 0.0]
    assert StarlightBudget.starlight_pick_chance(~w(gain_cost random_gift)) == 0.0
  end

  test "encounter_screens/3 follows boss, regular and focused node rules" do
    f1 = StarlightBudget.encounter_screens(1, 3.0, false)
    assert_in_delta f1.regular, 0.225, 1.0e-9
    assert f1.focused == 0.0
    assert_in_delta f1.total, 1.225, 1.0e-9

    f2 = StarlightBudget.encounter_screens(2, 3.0, false)
    assert_in_delta f2.regular, 2.0 * 0.10, 1.0e-9
    assert_in_delta f2.focused, 1.0 * 0.20, 1.0e-9

    assert StarlightBudget.encounter_screens(5, 0.0, false).total == 0.0
    assert StarlightBudget.encounter_screens(5, 0.0, true).boss == 1.0
    assert StarlightBudget.encounter_screens(4, 0.0, false).total == 1.0
  end

  test "starlight_reward_mean/0 is the middle of the 8 to 14 range" do
    assert StarlightBudget.starlight_reward_mean() == 11.0
  end
end
