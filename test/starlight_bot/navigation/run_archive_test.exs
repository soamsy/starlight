defmodule StarlightBot.Navigation.RunArchiveTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Navigation.RunArchive

  @now ~U[2026-11-06 12:00:00Z]

  defp run(n, ms), do: %{run: n, team: nil, failed?: false, ms: ms, floors: []}
  defp entry(kind, hours_ago, runs), do: %{kind: kind, started_at: DateTime.add(@now, -hours_ago * 3600), runs: runs}

  test "entry summarizes a finished session and ignores empty ones" do
    state = %{run_times_kind: :luxcavation, run_splits: [%{run: 1, floor: :exp, start_ms: 0}], run_started_at: @now, run_memory: %{}}

    assert %{kind: :luxcavation, started_at: @now, runs: [%{ms: 5_000}]} = RunArchive.entry(state, 5_000)
    assert RunArchive.entry(%{state | run_splits: []}, 5_000) == nil
    assert RunArchive.entry(%{state | run_times_kind: nil}, 5_000) == nil
  end

  test "push drops sessions older than 24 hours" do
    archive = [entry(:mirror_dungeon, 25, [run(1, 1)]), entry(:mirror_dungeon, 23, [run(1, 2)])]
    pushed = RunArchive.push(archive, entry(:luxcavation, 0, [run(1, 3)]), @now)

    assert Enum.map(pushed, & &1.kind) == [:mirror_dungeon, :luxcavation]
  end

  test "groups pile consecutive sessions of one kind, number md runs and subtotal each string" do
    groups =
      RunArchive.groups([
        entry(:mirror_dungeon, 5, [run(1, 100), run(2, 200)]),
        entry(:mirror_dungeon, 4, [run(1, 300)]),
        entry(:luxcavation, 3, [run(1, 50)]),
        entry(:luxcavation, 2, [run(1, 70)]),
        entry(:mirror_dungeon, 1, [run(1, 10)])
      ])

    assert Enum.map(groups, &{&1.kind, &1.ms}) == [mirror_dungeon: 600, luxcavation: 120, mirror_dungeon: 10]
    assert groups |> hd() |> Map.fetch!(:runs) |> Enum.map(& &1.run) == [1, 2, 3]
    assert RunArchive.total_ms(groups) == 730
  end
end
