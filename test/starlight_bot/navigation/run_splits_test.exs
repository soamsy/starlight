defmodule StarlightBot.Navigation.RunSplitsTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Navigation.RunSplits

  test "track opens a split only when the run or floor changes, starting the first at 0" do
    splits =
      []
      |> RunSplits.track(1, 1, 400)
      |> RunSplits.track(1, 1, 5_000)
      |> RunSplits.track(1, 2, 60_000)
      |> RunSplits.track(nil, 3, 61_000)
      |> RunSplits.track(2, 1, 90_000)

    assert splits == [%{run: 1, floor: 1, start_ms: 0}, %{run: 1, floor: 2, start_ms: 60_000}, %{run: 2, floor: 1, start_ms: 90_000}]
  end

  test "track accepts exp and thread as luxcavation rows" do
    splits = [] |> RunSplits.track(1, :exp, 500) |> RunSplits.track(1, :exp, 9_000) |> RunSplits.track(1, :thread, 40_000)

    assert splits == [%{run: 1, floor: :exp, start_ms: 0}, %{run: 1, floor: :thread, start_ms: 40_000}]
  end

  test "summary splits elapsed time into runs and floors that add up to it" do
    splits = [%{run: 1, floor: 1, start_ms: 0}, %{run: 1, floor: 2, start_ms: 60_000}, %{run: 2, floor: 1, start_ms: 90_000}]

    assert RunSplits.summary(splits, 100_000) == [
             %{run: 1, team: nil, failed?: false, ms: 90_000, floors: [%{floor: 1, ms: 60_000, pack: nil}, %{floor: 2, ms: 30_000, pack: nil}]},
             %{run: 2, team: nil, failed?: false, ms: 10_000, floors: [%{floor: 1, ms: 10_000, pack: nil}]}
           ]

    assert RunSplits.summary([], 5_000) == []
  end

  test "summary carries each run's team from its first split and flags failed runs" do
    splits =
      []
      |> RunSplits.track(1, 1, 0, "WildSinking")
      |> RunSplits.track(1, 2, 30_000, "WildSinking")
      |> RunSplits.track(2, 1, 50_000, "Saikai")

    assert [%{run: 1, team: "WildSinking", failed?: true}, %{run: 2, team: "Saikai", failed?: false}] =
             RunSplits.summary(splits, 60_000, [1])
  end

  test "summary attaches the theme pack picked for each run and floor, leaving unpicked floors nil" do
    splits = [%{run: 1, floor: 1, start_ms: 0}, %{run: 1, floor: 2, start_ms: 60_000}, %{run: 2, floor: 1, start_ms: 90_000}]
    picks = %{{1, 1} => "Hell's Chicken", {2, 1} => "Line 2"}

    assert [%{floors: [%{pack: "Hell's Chicken"}, %{pack: nil}]}, %{floors: [%{pack: "Line 2"}]}] =
             RunSplits.summary(splits, 100_000, [], picks)
  end
end
