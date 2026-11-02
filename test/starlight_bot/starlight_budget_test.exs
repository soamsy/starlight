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

  test "railway_floors/3 finds hard floors where a Line pack can appear at the given priorities" do
    packs = [
      %{id: "l2", name_en: "Line 2", normal_floors: "[]", hard_floors: "[4,5,6]"},
      %{id: "l1", name_en: "Line 1", normal_floors: "[]", hard_floors: "[5,6]"},
      %{id: "x", name_en: "Falling Flowers", normal_floors: "[3]", hard_floors: "[2,3]"}
    ]

    all_hard = %{"mode_schedule" => [%{"from_floor" => 1, "mode" => "hard"}]}
    assert StarlightBudget.railway_floors(all_hard, packs, ~w(hunt fine)) == [4, 5]
    assert StarlightBudget.railway_floors(all_hard, packs, ~w(hunt)) == []

    hunt_l1 = Map.put(all_hard, "packs", %{"l1" => %{"hard" => %{"5" => "hunt", "6" => "hunt"}}, "l2" => %{"hard" => %{"4" => "banned", "5" => "banned", "6" => "banned"}}})
    assert StarlightBudget.railway_floors(hunt_l1, packs, ~w(hunt fine)) == [5]
    assert StarlightBudget.railway_floors(hunt_l1, packs, ~w(hunt)) == [5]

    assert StarlightBudget.railway_floors(%{}, packs, ~w(hunt fine)) == []
  end

  test "cards_gain/1 is a flat amount per card" do
    assert StarlightBudget.cards_gain(0) == 0
    assert StarlightBudget.cards_gain(1) == 8
    assert StarlightBudget.cards_gain(2) == 16
  end
end
