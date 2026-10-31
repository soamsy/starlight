defmodule StarlightBot.SchedulerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.{RunnerForms, Scheduler}

  @settings %{window_start: "09:00", window_end: "13:00", last_fired_on: nil}

  test "the planned start lands in the first half of the window and is stable for a given day" do
    for day <- 1..60 do
      date = Date.add(~D[2026-10-01], day)
      planned = Scheduler.planned_start(date, @settings)

      assert NaiveDateTime.compare(planned, NaiveDateTime.new!(date, ~T[09:00:00])) != :lt
      assert NaiveDateTime.compare(planned, NaiveDateTime.new!(date, ~T[11:00:00])) != :gt
      assert planned == Scheduler.planned_start(date, @settings)
    end

    starts = for day <- 1..60, uniq: true, do: Scheduler.planned_start(Date.add(~D[2026-10-01], day), @settings).hour
    assert length(starts) > 1
  end

  test "due only between the planned start and the window end, and not again once fired that day" do
    date = ~D[2026-10-18]
    planned = Scheduler.planned_start(date, @settings)
    end_at = ~N[2026-10-18 13:00:00]

    assert Scheduler.due(NaiveDateTime.add(planned, -1), @settings) == :not_due
    assert Scheduler.due(planned, @settings) == {:due, date, end_at}
    assert Scheduler.due(~N[2026-10-18 12:59:59], @settings) == {:due, date, end_at}
    assert Scheduler.due(end_at, @settings) == :not_due
    assert Scheduler.due(~N[2026-10-18 12:59:59], %{@settings | last_fired_on: date}) == :not_due
  end

  test "a window that ends before it starts runs past midnight and stays due into the next day" do
    settings = %{@settings | window_start: "22:00", window_end: "04:00"}
    date = ~D[2026-10-18]

    assert Scheduler.window(date, settings) == {~N[2026-10-18 22:00:00], ~N[2026-10-19 04:00:00]}
    assert {:due, ^date, ~N[2026-10-19 04:00:00]} = Scheduler.due(~N[2026-10-19 03:59:00], settings)
    assert Scheduler.due(~N[2026-10-19 04:00:00], settings) == :not_due
  end

  test "next_planned moves to tomorrow once today's run has fired or the window has passed" do
    date = ~D[2026-10-18]
    assert {^date, _, _} = Scheduler.next_planned(~N[2026-10-18 08:00:00], @settings)
    assert {~D[2026-10-19], _, _} = Scheduler.next_planned(~N[2026-10-18 08:00:00], %{@settings | last_fired_on: date})
    assert {~D[2026-10-19], _, _} = Scheduler.next_planned(~N[2026-10-18 14:00:00], @settings)
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
      runner: "luxcavation",
      window_start: "22:00",
      window_end: "02:30",
      launch_mode: "steam",
      steam_app_id: "1973530",
      exe_path: "",
      launch_timeout_s: 900
    }

    @lux_form %{"exp_team_ids" => List.duplicate("7", 4), "thread_team_ids" => List.duplicate("7", 7), "exp_consecutive" => "1", "exp_repeats" => "2", "thread_consecutive" => "3", "thread_repeats" => "1", "collect_xp" => "true", "collect_enkephalin" => "false"}
    @md_form %{"team_ids" => ["5"], "start_index" => "0", "run_count" => "2", "rewards" => "weekly", "collect_xp" => "true"}

    test "save_settings stores the schedule and get_settings reads it back" do
      RunnerForms.put("luxcavation", @lux_form)
      assert {:ok, settings} = Scheduler.save_settings(@attrs)
      assert settings == Scheduler.get_settings()
      assert %{enabled: true, runner: "luxcavation", window_start: "22:00", window_end: "02:30", launch_timeout_s: 900} = settings

      {:ok, _} = Scheduler.mark_fired(~D[2026-10-18])
      assert Scheduler.get_settings().last_fired_on == ~D[2026-10-18]
    end

    test "save_settings rejects a schedule it couldn't run" do
      assert {:error, "the luxcavation runner page isn't set up to run"} = Scheduler.save_settings(@attrs)
      RunnerForms.put("luxcavation", @lux_form)
      assert {:error, "the mirror dungeon runner page isn't set up to run"} = Scheduler.save_settings(%{@attrs | runner: "mirror_dungeon"})
      assert {:error, "times must be HH:MM"} = Scheduler.save_settings(%{@attrs | window_start: "9am"})
      assert {:error, _} = Scheduler.save_settings(%{@attrs | window_end: "22:00"})
      assert {:error, _} = Scheduler.save_settings(%{@attrs | steam_app_id: "limbus"})
      assert {:error, _} = Scheduler.save_settings(%{@attrs | launch_mode: "exe", exe_path: "/nope/LimbusCompany.exe"})
      assert {:error, _} = Scheduler.save_settings(%{@attrs | launch_timeout_s: nil})
    end

    test "scheduled runs use the runner pages' current forms" do
      RunnerForms.put("luxcavation", Map.put(@lux_form, "then", "mirror_dungeon"))
      assert {:error, "the mirror dungeon runner page isn't set up to run"} = Scheduler.save_settings(@attrs)

      RunnerForms.put("mirror_dungeon", @md_form)
      assert {:ok, settings} = Scheduler.save_settings(@attrs)
      assert {:luxcavation_then_mirror_dungeon, {:run_luxcavation, %{exp: %{id: 7, hook: nil}, thread: %{id: 7, hook: nil}}, 1, 2, 3, 1, true, false, 0}, {:run_mirror_dungeon, [%{id: 5, hook: "team_burn"}], 2, _}} = Scheduler.runner_action(settings)

      RunnerForms.put("mirror_dungeon", %{@md_form | "run_count" => "5"})
      assert {_, _, {:run_mirror_dungeon, [%{id: 5, hook: "team_burn"}], 5, _}} = Scheduler.runner_action(settings)

      RunnerForms.put("luxcavation", @lux_form)
      assert {:run_luxcavation, _, 1, 2, 3, 1, true, false, 0} = Scheduler.runner_action(settings)
    end
  end
end
