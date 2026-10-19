defmodule StarlightBot.Navigation.ScreenTimesTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Navigation.ScreenTimes

  @wall ~U[2026-10-16 12:00:00.000000Z]

  defp track(times, key, at_ms), do: ScreenTimes.track(times, key, at_ms, @wall)

  defp sample do
    %ScreenTimes{}
    |> track(%{run: 1}, 0)
    |> track(%{screen: :shop, run: 1, floor: 1}, 2_000)
    |> track(%{screen: :shop, run: 1, floor: 1}, 3_000)
    |> track(%{screen: :shop, task: "shop: Buy list", step: "→ shop_buy", run: 1, floor: 1}, 4_000)
    |> track(%{run: 1, floor: 1}, 10_000)
    |> track(%{screen: :battle, step: "→ battle_playing", run: 1, floor: 2}, 11_000)
    |> track(%{screen: :battle, step: "→ battle_turn_or_over", run: 1, floor: 2}, 21_000)
    |> track(%{run: 2, floor: 1}, 41_000)
    |> track(%{screen: :shop, run: 2, floor: 1}, 42_000)
  end

  test "repeated keys extend the open segment and zero-length segments are dropped" do
    segments = ScreenTimes.segments(sample(), 45_000)

    assert Enum.map(segments, &{&1.screen, &1.start_ms, &1.end_ms}) == [
             {nil, 0, 2_000},
             {:shop, 2_000, 4_000},
             {:shop, 4_000, 10_000},
             {nil, 10_000, 11_000},
             {:battle, 11_000, 21_000},
             {:battle, 21_000, 41_000},
             {nil, 41_000, 42_000},
             {:shop, 42_000, 45_000}
           ]

    assert ScreenTimes.current_run(sample()) == 2
  end

  test "breakdown ranks screens with visits, longest visit, and per-step details" do
    [battle, shop, none] = sample() |> ScreenTimes.segments(45_000) |> ScreenTimes.breakdown()

    assert %{screen: :battle, ms: 30_000, visits: 1, longest_ms: 30_000} = battle
    assert Enum.map(battle.details, &{&1.detail, &1.ms}) == [{"→ battle_turn_or_over", 20_000}, {"→ battle_playing", 10_000}]

    assert %{screen: :shop, ms: 11_000, visits: 2, longest_ms: 8_000} = shop
    assert Enum.map(shop.details, &{&1.detail, &1.ms}) == [{"shop: Buy list · → shop_buy", 6_000}, {"", 5_000}]

    assert %{screen: nil, ms: 4_000, visits: 3} = none
  end

  test "timeline splits segments into runs, merged visits, and floors" do
    [run1, run2] = sample() |> ScreenTimes.segments(45_000) |> ScreenTimes.timeline()

    assert %{run: 1, start_ms: 0, ms: 41_000} = run1
    assert Enum.map(run1.visits, &{&1.screen, &1.ms}) == [{nil, 2_000}, {:shop, 8_000}, {nil, 1_000}, {:battle, 30_000}]
    assert Enum.map(run1.floors, &{&1.floor, &1.ms}) == [{nil, 2_000}, {1, 9_000}, {2, 30_000}]
    assert %{run: 2, start_ms: 41_000, ms: 4_000} = run2
  end

  test "nothing is recorded before tracking starts" do
    assert ScreenTimes.segments(%ScreenTimes{}, 0) == []
    assert ScreenTimes.breakdown([]) == []
    assert ScreenTimes.current_run(%ScreenTimes{}) == nil
  end
end
