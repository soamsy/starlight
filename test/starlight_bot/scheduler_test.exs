defmodule StarlightBot.SchedulerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.{RunnerForms, Scheduler}

  @settings %{window_start: "09:00", window_end: "13:00"}

  test "the planned start lands within 15 minutes after the window start and is stable for a given day" do
    for day <- 1..60 do
      date = Date.add(~D[2026-10-01], day)
      planned = Scheduler.planned_start(date, @settings)

      assert NaiveDateTime.compare(planned, NaiveDateTime.new!(date, ~T[09:00:00])) != :lt
      assert NaiveDateTime.compare(planned, NaiveDateTime.new!(date, ~T[09:15:00])) != :gt
      assert planned == Scheduler.planned_start(date, @settings)
    end

    starts = for day <- 1..60, uniq: true, do: Scheduler.planned_start(Date.add(~D[2026-10-01], day), @settings).minute
    assert length(starts) > 1
  end

  test "the jitter shrinks for windows shorter than half an hour and the latest start is shown" do
    assert Scheduler.latest_start_time(@settings) == ~T[09:15:00]
    assert Scheduler.latest_start_time(%{@settings | window_end: "09:20"}) == ~T[09:10:00]
  end

  test "due only between the planned start and the window end" do
    date = ~D[2026-10-18]
    planned = Scheduler.planned_start(date, @settings)
    end_at = ~N[2026-10-18 13:00:00]

    assert Scheduler.due(NaiveDateTime.add(planned, -1), @settings) == :not_due
    assert Scheduler.due(planned, @settings) == {:due, date, end_at}
    assert Scheduler.due(~N[2026-10-18 12:59:59], @settings) == {:due, date, end_at}
    assert Scheduler.due(end_at, @settings) == :not_due
  end

  test "a window that ends before it starts runs past midnight and stays due into the next day" do
    settings = %{@settings | window_start: "22:00", window_end: "04:00"}
    date = ~D[2026-10-18]

    assert Scheduler.window(date, settings) == {~N[2026-10-18 22:00:00], ~N[2026-10-19 04:00:00]}
    assert {:due, ^date, ~N[2026-10-19 04:00:00]} = Scheduler.due(~N[2026-10-19 03:59:00], settings)
    assert Scheduler.due(~N[2026-10-19 04:00:00], settings) == :not_due
  end

  test "next_planned moves to tomorrow once the window has passed" do
    date = ~D[2026-10-18]
    assert {^date, _, _} = Scheduler.next_planned(~N[2026-10-18 08:00:00], @settings)
    assert {~D[2026-10-19], _, _} = Scheduler.next_planned(~N[2026-10-18 14:00:00], @settings)
  end

  test "the day timeline gives the window, the start shift span and the current minute" do
    now = ~N[2026-10-18 10:30:00]
    timeline = Scheduler.day_timeline(now, @settings, nil)
    assert timeline.windows == [{540, 780}]
    assert timeline.start_span == {540, 555}
    assert timeline.now == 630
    assert timeline.planned in 540..555
    assert timeline.blocked == nil

    overnight = Scheduler.day_timeline(now, %{window_start: "22:00", window_end: "04:00"}, nil)
    assert overnight.windows == [{0, 240}, {1320, 1440}]

    assert Scheduler.day_timeline(now, %{window_start: "9am", window_end: "13:00"}, nil) == nil
  end

  describe "holds and cancels" do
    setup do
      :ok = StarlightBot.TestDB.checkout()
    end

    test "nothing blocks by default, a hold blocks until it passes, resume clears it" do
      assert Scheduler.blocked() == nil
      :ok = Scheduler.hold("2")
      assert {:hold, until} = Scheduler.blocked()
      assert_in_delta DateTime.diff(until, DateTime.utc_now()), 7200, 5
      :ok = Scheduler.hold("clear")
      assert Scheduler.blocked() == nil
    end

    test "rest of day holds until the next 9 PM UTC reset" do
      :ok = Scheduler.hold("day")
      {:hold, until} = Scheduler.blocked()
      assert until.hour == 21 and until.minute == 0
      assert DateTime.diff(until, DateTime.utc_now()) in 1..86_400
    end

    test "a canceled run blocks for an hour and resume overrides it" do
      :ok = StarlightBot.RunHistory.record_canceled(:luxcavation)
      assert {:canceled, until} = Scheduler.blocked()
      assert_in_delta DateTime.diff(until, DateTime.utc_now()), 3600, 5
      Process.sleep(1100)
      :ok = Scheduler.hold("clear")
      assert Scheduler.blocked() == nil
    end

    test "the outlook says what is waiting and when it will start" do
      settings = Map.put(@settings, :enabled, true)
      remaining = %{"exp" => 3, "thread" => 0, "md" => 1}
      now = ~N[2026-10-18 08:00:00]
      planned = Scheduler.planned_start(~D[2026-10-18], settings)
      text = Scheduler.outlook(now, settings, remaining, false, nil)
      assert text =~ "Will start 3 EXP waves, 1 MD run at #{Scheduler.clock12(planned)} today"

      assert Scheduler.outlook(now, settings, remaining, true, nil) =~ "waiting for it to finish before starting 3 EXP waves, 1 MD run"
      assert Scheduler.outlook(now, %{settings | enabled: false}, remaining, false, nil) =~ "Scheduler is off"

      blocked = {:hold, now |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(3600)}
      assert Scheduler.outlook(now, settings, remaining, false, blocked) =~ "You paused the schedulers until"
    end
  end

  describe "settings" do
    setup do
      :ok = StarlightBot.TestDB.checkout()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      StarlightBot.Repo.insert_all("teams", [%{id: 5, name: "Burn", hooks: ~s(["team_burn"]), inserted_at: now, updated_at: now}])
      :ok
    end

    @attrs %{
      enabled: true,
      window_start: "22:00",
      window_end: "02:30",
      launch_mode: "steam",
      steam_app_id: "1973530",
      exe_path: "",
      launch_timeout_s: 900,
      exp_waves: 2,
      thread_waves: 3,
      md_runs: 0
    }

    @lux_form %{"exp_team_ids" => List.duplicate("7", 4), "thread_team_ids" => List.duplicate("7", 7), "exp_waves" => "9", "thread_waves" => "9", "collect_xp" => "true", "collect_enkephalin" => "false"}
    @md_form %{"team_ids" => ["5"], "start_index" => "0", "run_count" => "9", "rewards" => "weekly", "collect_xp" => "true"}

    test "save_settings stores the schedule and get_settings reads it back" do
      RunnerForms.put("luxcavation", @lux_form)
      assert {:ok, settings} = Scheduler.save_settings(@attrs)
      assert settings == Scheduler.get_settings()
      assert %{enabled: true, window_start: "22:00", window_end: "02:30", launch_timeout_s: 900, exp_waves: 2, thread_waves: 3, md_runs: 0} = settings
    end

    test "save_settings rejects a schedule it couldn't run" do
      assert {:error, "the luxcavation runner page isn't set up to run"} = Scheduler.save_settings(@attrs)
      RunnerForms.put("luxcavation", @lux_form)
      assert {:error, "the mirror dungeon runner page isn't set up to run"} = Scheduler.save_settings(%{@attrs | md_runs: 1})
      assert {:ok, _} = Scheduler.save_settings(%{@attrs | exp_waves: 0, thread_waves: 0})
      assert {:error, "times must be HH:MM"} = Scheduler.save_settings(%{@attrs | window_start: "9am"})
      assert {:error, _} = Scheduler.save_settings(%{@attrs | window_end: "22:00"})
      assert {:error, _} = Scheduler.save_settings(%{@attrs | exp_waves: -1})
      assert {:error, _} = Scheduler.save_settings(%{@attrs | md_runs: nil})
      assert {:error, _} = Scheduler.save_settings(%{@attrs | steam_app_id: "limbus"})
      assert {:error, _} = Scheduler.save_settings(%{@attrs | launch_mode: "exe", exe_path: "/nope/LimbusCompany.exe"})
      assert {:error, _} = Scheduler.save_settings(%{@attrs | launch_timeout_s: nil})
    end

    test "scheduled runs use the runner pages' forms with the waves and runs left today" do
      RunnerForms.put("luxcavation", @lux_form)
      RunnerForms.put("mirror_dungeon", @md_form)

      assert {:run_luxcavation, %{exp: %{id: 7, hook: nil}, thread: %{id: 7, hook: nil}}, 2, 3, true, false, 0} = Scheduler.runner_action(%{"exp" => 2, "thread" => 3, "md" => 0})
      assert {:run_luxcavation, _, 0, 3, true, false, 0} = Scheduler.runner_action(%{"exp" => 0, "thread" => 3, "md" => 0})
      assert {:run_mirror_dungeon, [%{id: 5, hook: "team_burn"}], 4, _} = Scheduler.runner_action(%{"exp" => 0, "thread" => 0, "md" => 4})

      assert {:luxcavation_then_mirror_dungeon, {:run_luxcavation, _, 1, 0, _, _, _}, {:run_mirror_dungeon, _, 2, _}} =
               Scheduler.runner_action(%{"exp" => 1, "thread" => 0, "md" => 2})

      assert Scheduler.runner_action(%{"exp" => 0, "thread" => 0, "md" => 0}) == nil
    end
  end
end
