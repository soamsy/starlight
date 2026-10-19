defmodule StarlightBotWeb.Live.MirrorDungeonLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias StarlightBotWeb.Live.MirrorDungeonLive, as: Live

  @teams [%{id: 5, name: "Burn"}, %{id: 10, name: "Saikai"}]

  defp socket(team_ids) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}, teams: @teams, team_ids: team_ids, start_index: 0, run_count: "1", weekly_bonus: true, collect_enkephalin: false, collect_xp: false, enkephalin_convert_count: "0", pending_action: nil, countdown: nil}
    }
  end

  defp event(socket, name, params) do
    {:noreply, socket} = Live.handle_event(name, params, socket)
    socket
  end

  test "parse_team_ids keeps known ids in order, repeats included, and falls back when none are valid" do
    assert Live.parse_team_ids(["10", "5", "10"], @teams) == [10, 5, 10]
    assert Live.parse_team_ids(["10", "99", "x"], @teams) == [10]
    assert Live.parse_team_ids(["99"], @teams, [5]) == [5]
    assert Live.parse_team_ids(nil, @teams, [5]) == [5]
  end

  test "the cycle grows by repeating the last team and never shrinks below one" do
    socket = socket([5]) |> event("add_cycle_team", %{}) |> event("update_form", %{"team_ids" => ["5", "10"], "run_count" => "3"})
    assert socket.assigns.team_ids == [5, 10]

    socket = socket |> event("add_cycle_team", %{}) |> event("remove_cycle_team", %{"index" => "0"})
    assert socket.assigns.team_ids == [10, 10]

    socket = socket |> event("remove_cycle_team", %{"index" => "1"}) |> event("remove_cycle_team", %{"index" => "0"})
    assert socket.assigns.team_ids == [10]
  end

  test "restoring a saved form reads the team_ids[] list" do
    socket = event(socket([5]), "restore_form", %{"team_ids[]" => ["10", "5"], "run_count" => "4", "weekly_bonus" => "true"})
    assert socket.assigns.team_ids == [10, 5]
    assert socket.assigns.run_count == "4"
  end

  test "running queues the whole cycle" do
    socket = event(socket([5]), "run", %{"team_ids" => ["10", "5"], "run_count" => "2"})
    assert {:run_mirror_dungeon, [10, 5], 2, %{weekly_bonus?: false, collect_enkephalin?: false}} = socket.assigns.pending_action
    assert Live.pending_action_label(socket.assigns.pending_action) == "mirror dungeon: 2 run(s) cycling 2 teams"
  end

  test "collecting enkephalin carries the lunacy conversion count into the run config" do
    params = %{"team_ids" => ["5"], "run_count" => "2", "collect_enkephalin" => "true", "enkephalin_convert_count" => "2"}
    socket = event(socket([5]), "run", params)

    assert {:run_mirror_dungeon, [5], 2, %{collect_enkephalin?: true, enkephalin_convert_count: 2}} = socket.assigns.pending_action
    assert Live.pending_action_label(socket.assigns.pending_action) =~ "enkephalin before each run"

    socket = event(socket([5]), "run", %{params | "enkephalin_convert_count" => "9"})
    assert socket.assigns.pending_action == nil
  end

  test "the starred team starts the run and the cycle wraps around from it" do
    socket = event(socket([5]), "run", %{"team_ids" => ["5", "10", "7"], "start_index" => "1", "run_count" => "3"})
    assert {:run_mirror_dungeon, [10, 5], 3, _} = socket.assigns.pending_action

    teams = @teams ++ [%{id: 7, name: "Bleed"}]
    socket = %{socket([5]) | assigns: %{socket([5]).assigns | teams: teams}}
    socket = event(socket, "run", %{"team_ids" => ["5", "10", "7"], "start_index" => "2", "run_count" => "3"})
    assert {:run_mirror_dungeon, [7, 5, 10], 3, _} = socket.assigns.pending_action

    socket = event(socket, "run", %{"team_ids" => ["5", "10"], "start_index" => "9", "run_count" => "1"})
    assert {:run_mirror_dungeon, [5, 10], 1, _} = socket.assigns.pending_action
  end

  test "the star follows its team through drags and removals" do
    socket =
      socket([5, 10, 5, 10])
      |> event("set_cycle_start", %{"index" => "2"})
      |> event("reorder_cycle", %{"ids" => ["2", "0", "1", "3"]})

    assert socket.assigns.team_ids == [5, 5, 10, 10]
    assert socket.assigns.start_index == 0

    socket = socket |> event("reorder_cycle", %{"ids" => ["0", "0", "1", "2"]})
    assert socket.assigns.team_ids == [5, 5, 10, 10]

    socket = socket |> event("set_cycle_start", %{"index" => "2"}) |> event("remove_cycle_team", %{"index" => "0"})
    assert socket.assigns.start_index == 1

    socket = socket |> event("remove_cycle_team", %{"index" => "2"}) |> event("remove_cycle_team", %{"index" => "1"})
    assert socket.assigns.team_ids == [5]
    assert socket.assigns.start_index == 0
  end

  test "restoring a saved form keeps the starter when it's still in range" do
    socket = event(socket([5]), "restore_form", %{"team_ids[]" => ["10", "5"], "start_index" => "1", "run_count" => "4"})
    assert socket.assigns.start_index == 1
    socket = event(socket, "update_form", %{"team_ids" => ["10"], "start_index" => "1", "run_count" => "4"})
    assert socket.assigns.start_index == 0
  end

  test "elapsed keeps ticking from the last snapshot only while running" do
    running = %{elapsed_ms: 61_000, running?: true, received_ms: 1_000}
    assert Live.elapsed_ms(running, 3_000) == 63_000
    assert Live.elapsed_ms(%{running | running?: false}, 3_000) == 61_000
    assert Live.elapsed_ms(nil, 3_000) == nil
  end

  test "format_elapsed shows hours only when needed" do
    assert Live.format_elapsed(65_000) == "01:05"
    assert Live.format_elapsed(3_725_999) == "1:02:05"
  end

  test "the run times sidebar lists each run's floors and the total" do
    splits = [%{run: 1, floor: 1, start_ms: 0, team: "WildSinking"}, %{run: 1, floor: 2, start_ms: 60_000, team: "WildSinking"}]
    runs = Live.run_times(splits, %{elapsed_ms: 75_000, running?: false, received_ms: 0}, 0, %{failed_runs: [1]})
    html = %{runs: runs, live_last?: false} |> Live.run_times() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

    assert html =~ "Run 1"
    assert html =~ "WildSinking"
    assert html =~ "failed"
    assert html =~ "Floor 2"
    assert html =~ "00:15"
    assert html =~ "01:15"
  end

  @segments [
    %{screen: :battle, task: nil, step: "→ battle_playing", run: 1, floor: 1, start_ms: 0, end_ms: 30_000},
    %{screen: nil, task: nil, step: nil, run: 1, floor: 1, start_ms: 30_000, end_ms: 35_000},
    %{screen: :battle, task: nil, step: "→ battle_turn_or_over", run: 1, floor: 2, start_ms: 35_000, end_ms: 40_000}
  ]

  test "the screen times breakdown ranks screens with their share, visits, and steps" do
    html = render_component(&Live.screen_times/1, segments: @segments)

    assert html =~ "battle"
    assert html =~ "88%"
    assert html =~ "No screen (localizing / unrecognized)"
    assert html =~ "13%"
    assert html =~ "→ battle_playing"
    assert html =~ "(no step recorded)"
    assert html =~ "Floor 2"
  end

  test "the floor filter narrows the breakdown" do
    html = render_component(&Live.screen_times/1, segments: @segments, filter: %{run: nil, floor: 2})

    assert html =~ "→ battle_turn_or_over"
    refute html =~ "→ battle_playing"
    refute html =~ "No screen (localizing / unrecognized)"
  end

  test "the timeline shows each run as a bar of visits with their offsets" do
    html = render_component(&Live.screen_times/1, segments: @segments, view: "timeline")

    assert html =~ "Run 1"
    assert html =~ "3 visits"
    assert html =~ "width: 75.0%"
    assert html =~ "00:35"
  end

  test "an empty session says nothing is recorded" do
    assert render_component(&Live.screen_times/1, segments: []) =~ "No screen time recorded yet"
  end
end
