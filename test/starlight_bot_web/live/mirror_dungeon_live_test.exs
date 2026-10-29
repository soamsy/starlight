defmodule StarlightBotWeb.Live.MirrorDungeonLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias StarlightBot.RunnerForms
  alias StarlightBotWeb.Live.MirrorDungeonLive, as: Live

  @teams [%{id: 5, name: "Burn", hooks: ["team_burn"]}, %{id: 10, name: "Saikai", hooks: ["team_slash", "team_pierce"]}]
  @burn %{id: 5, hook: "team_burn"}
  @saikai %{id: 10, hook: "team_slash"}
  @saikai_pierce %{id: 10, hook: "team_pierce"}
  @bleed %{id: 7, hook: "team_bleed"}

  defp socket(picks) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}, teams: @teams, picks: picks, start_index: 0, run_count: "1", rewards: "weekly", collect_enkephalin: false, collect_xp: false, capture_ego_gifts: false, enkephalin_convert_count: "0", pending_action: nil, countdown: nil, phase: :idle, other_running?: false}
    }
  end

  setup do
    :ok = StarlightBot.TestDB.checkout()
  end

  defp event(socket, name, params) do
    {:noreply, socket} = Live.handle_event(name, params, socket)
    socket
  end

  test "parse_team_picks keeps known teams in order, repeats included, and falls back when none are valid" do
    assert RunnerForms.parse_team_picks(["10", "5", "10"], nil, @teams) == [@saikai, @burn, @saikai]
    assert RunnerForms.parse_team_picks(["10", "99", "x"], nil, @teams) == [@saikai]
    assert RunnerForms.parse_team_picks(["99"], nil, @teams, [@burn]) == [@burn]
    assert RunnerForms.parse_team_picks(nil, nil, @teams, [@burn]) == [@burn]
  end

  test "parse_team_picks keeps each row's hook and falls back to the team's first hook" do
    assert RunnerForms.parse_team_picks(["10", "10"], ["team_pierce", "team_slash"], @teams) == [@saikai_pierce, @saikai]
    assert RunnerForms.parse_team_picks(["10", "5"], ["team_burn", "team_pierce"], @teams) == [@saikai, @burn]
    assert RunnerForms.parse_team_picks(["5", "10"], ["team_burn"], @teams) == [@burn, @saikai]
  end

  test "the cycle grows by repeating the last team and never shrinks below one" do
    socket = socket([@burn]) |> event("add_cycle_team", %{}) |> event("update_form", %{"team_ids" => ["5", "10"], "run_count" => "3"})
    assert socket.assigns.picks == [@burn, @saikai]

    socket = socket |> event("add_cycle_team", %{}) |> event("remove_cycle_team", %{"index" => "0"})
    assert socket.assigns.picks == [@saikai, @saikai]

    socket = socket |> event("remove_cycle_team", %{"index" => "1"}) |> event("remove_cycle_team", %{"index" => "0"})
    assert socket.assigns.picks == [@saikai]
  end

  test "restoring a saved form reads its team list and hooks" do
    socket = Live.restore_form(socket([@burn]), %{"team_ids" => ["10", "5"], "team_hooks" => ["team_pierce", "team_burn"], "run_count" => "4", "rewards" => "claim"})
    assert socket.assigns.picks == [@saikai_pierce, @burn]
    assert socket.assigns.run_count == "4"
    assert socket.assigns.rewards == "claim"
    assert Live.restore_form(socket, nil) == socket
  end

  test "every form change is saved, and the saved form makes the same run" do
    event(socket([@burn]), "update_form", %{"team_ids" => ["10", "5"], "team_hooks" => ["team_pierce", "team_burn"], "start_index" => "1", "run_count" => "3", "collect_xp" => "true"})

    saved = RunnerForms.get("mirror_dungeon")
    assert %{"team_ids" => ["10", "5"], "team_hooks" => ["team_pierce", "team_burn"], "start_index" => "1", "run_count" => "3", "collect_xp" => "true", "rewards" => "weekly"} = saved
    assert {:ok, {:run_mirror_dungeon, [@burn, @saikai_pierce], 3, %{collect_xp?: true}}} = RunnerForms.mirror_dungeon_action(saved, @teams)
  end

  test "running queues the whole cycle" do
    socket = event(socket([@burn]), "run", %{"team_ids" => ["10", "5"], "run_count" => "2"})
    assert {:run_mirror_dungeon, [@saikai, @burn], 2, %{rewards: :none, collect_enkephalin?: false}} = socket.assigns.pending_action
    assert Live.pending_action_label(socket.assigns.pending_action) == "mirror dungeon: 2 run(s) cycling 2 teams (dry run, refusing rewards)"
  end

  test "collecting enkephalin carries the lunacy conversion count into the run config" do
    params = %{"team_ids" => ["5"], "run_count" => "2", "collect_enkephalin" => "true", "enkephalin_convert_count" => "2"}
    socket = event(socket([@burn]), "run", params)

    assert {:run_mirror_dungeon, [@burn], 2, %{collect_enkephalin?: true, enkephalin_convert_count: 2}} = socket.assigns.pending_action
    assert Live.pending_action_label(socket.assigns.pending_action) =~ "enkephalin before each run"

    socket = event(socket([@burn]), "run", %{params | "enkephalin_convert_count" => "9"})
    assert socket.assigns.pending_action == nil
  end

  test "the starred team starts the run and the cycle wraps around from it" do
    socket = event(socket([@burn]), "run", %{"team_ids" => ["5", "10", "7"], "start_index" => "1", "run_count" => "3"})
    assert {:run_mirror_dungeon, [@saikai, @burn], 3, _} = socket.assigns.pending_action

    teams = @teams ++ [%{id: 7, name: "Bleed", hooks: ["team_bleed"]}]
    socket = %{socket([@burn]) | assigns: %{socket([@burn]).assigns | teams: teams}}
    socket = event(socket, "run", %{"team_ids" => ["5", "10", "7"], "start_index" => "2", "run_count" => "3"})
    assert {:run_mirror_dungeon, [@bleed, @burn, @saikai], 3, _} = socket.assigns.pending_action

    socket = event(socket, "run", %{"team_ids" => ["5", "10"], "start_index" => "9", "run_count" => "1"})
    assert {:run_mirror_dungeon, [@burn, @saikai], 1, _} = socket.assigns.pending_action
  end

  test "the star follows its team through drags and removals" do
    socket =
      socket([@burn, @saikai, @burn, @saikai])
      |> event("set_cycle_start", %{"index" => "2"})
      |> event("reorder_cycle", %{"ids" => ["2", "0", "1", "3"]})

    assert socket.assigns.picks == [@burn, @burn, @saikai, @saikai]
    assert socket.assigns.start_index == 0

    socket = socket |> event("reorder_cycle", %{"ids" => ["0", "0", "1", "2"]})
    assert socket.assigns.picks == [@burn, @burn, @saikai, @saikai]

    socket = socket |> event("set_cycle_start", %{"index" => "2"}) |> event("remove_cycle_team", %{"index" => "0"})
    assert socket.assigns.start_index == 1

    socket = socket |> event("remove_cycle_team", %{"index" => "2"}) |> event("remove_cycle_team", %{"index" => "1"})
    assert socket.assigns.picks == [@burn]
    assert socket.assigns.start_index == 0
  end

  test "the cycle can't be edited while a run is active" do
    socket = socket([@burn, @saikai])
    running = %{socket | assigns: %{socket.assigns | phase: :paused}}

    running =
      running
      |> event("set_cycle_start", %{"index" => "1"})
      |> event("reorder_cycle", %{"ids" => ["1", "0"]})
      |> event("add_cycle_team", %{})
      |> event("remove_cycle_team", %{"index" => "0"})
      |> event("update_form", %{"team_ids" => ["10"], "start_index" => "1", "run_count" => "5"})

    assert running.assigns.picks == [@burn, @saikai]
    assert running.assigns.start_index == 0
    assert running.assigns.run_count == "5"
  end

  test "a completed run moves the saved star to the next team, wrapping around" do
    event(socket([@burn]), "update_form", %{"team_ids" => ["5", "10", "5"], "start_index" => "1", "run_count" => "3"})

    RunnerForms.advance_mirror_dungeon_start()
    assert %{"start_index" => "2", "run_count" => "3"} = RunnerForms.get("mirror_dungeon")

    RunnerForms.advance_mirror_dungeon_start()
    assert %{"start_index" => "0"} = RunnerForms.get("mirror_dungeon")
  end

  test "restoring a saved form keeps the starter when it's still in range" do
    socket = Live.restore_form(socket([@burn]), %{"team_ids" => ["10", "5"], "start_index" => "1", "run_count" => "4"})
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
