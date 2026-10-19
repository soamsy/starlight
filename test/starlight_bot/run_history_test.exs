defmodule StarlightBot.RunHistoryTest do
  use ExUnit.Case, async: false

  alias StarlightBot.{Repo, RunHistory}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "a saved run lists with its summary and reloads its segments relative to the run start" do
    wall = ~U[2026-10-16 12:00:00.000000Z]

    segments = [
      %{screen: :shop, task: "shop: Buy list", step: "→ shop_buy", run: 2, floor: 1, start_ms: 60_000, end_ms: 66_000, started_at: wall},
      %{screen: nil, task: nil, step: nil, run: 2, floor: 2, start_ms: 66_000, end_ms: 67_500, started_at: wall},
      %{screen: :battle, task: nil, step: "→ battle_playing", run: 2, floor: 2, start_ms: 67_500, end_ms: 97_500, started_at: wall}
    ]

    {:ok, id} = RunHistory.save_run(%{team_id: 5, team_name: "Burn", result: "success"}, segments)

    assert [%{id: ^id, team_name: "Burn", result: "success", floors_completed: 2, duration_seconds: 37}] = RunHistory.list_runs()

    assert [shop, none, battle] = RunHistory.segments(id)
    assert %{screen: "shop", task: "shop: Buy list", step: "→ shop_buy", floor: 1, run: ^id, start_ms: 0, end_ms: 6_000} = shop
    assert %{screen: nil, start_ms: 6_000, end_ms: 7_500} = none
    assert %{screen: "battle", start_ms: 7_500, end_ms: 37_500} = battle
  end

  test "an interrupted run only counts floors it finished, and empty runs are not saved" do
    segment = %{screen: :battle, task: nil, step: nil, run: 1, floor: 3, start_ms: 0, end_ms: 1_000, started_at: DateTime.utc_now()}
    {:ok, _} = RunHistory.save_run(%{result: "interrupted"}, [segment])

    assert [%{floors_completed: 2, team_name: nil}] = RunHistory.list_runs()
    assert RunHistory.save_run(%{result: "success"}, []) == {:error, :no_segments}
  end
end
