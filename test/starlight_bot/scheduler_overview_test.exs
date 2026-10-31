defmodule StarlightBot.Scheduler.OverviewTest do
  use ExUnit.Case, async: true

  alias StarlightBot.{EnkephalinSchedule, Scheduler}
  alias StarlightBot.Scheduler.Overview

  @now ~N[2026-10-18 08:00:00]
  @runs %{enabled: true, window_start: "09:00", window_end: "13:00"}
  @charger %{enabled: true, window_start: "10:00", window_end: "18:00", interval_minutes: 180, last_converted_at: nil}
  @pending %{"exp" => 1, "thread" => 0, "md" => 0}
  @done %{"exp" => 0, "thread" => 0, "md" => 0}
  @later DateTime.from_naive!(~N[2026-10-18 09:00:00], "Etc/UTC")

  setup do
    :ok = StarlightBot.TestDB.checkout()
  end

  defp hold_until(local) do
    base = DateTime.from_naive!(local, "Etc/UTC")
    DateTime.add(base, -NaiveDateTime.diff(Scheduler.to_local(base), local))
  end

  describe "charger" do
    test "waits for its window and says so" do
      assert EnkephalinSchedule.next_charge(@now, @charger, nil) == ~N[2026-10-18 10:00:00]
      text = EnkephalinSchedule.outlook(@now, @charger, nil, false)
      assert text =~ "Will charge enkephalin at 10:00 AM today, in 2h"
      assert text =~ "Waiting on the charging window opening at 10:00 AM"
    end

    test "reports the interval when it outlasts a hold" do
      charger = %{@charger | last_converted_at: ~N[2026-10-18 10:30:00]}
      blocked = {:canceled, hold_until(~N[2026-10-18 12:00:00])}
      assert EnkephalinSchedule.next_charge(@now, charger, blocked) == ~N[2026-10-18 13:30:00]
      text = EnkephalinSchedule.outlook(@now, charger, blocked, false)
      assert text =~ "interval since the last charge"
      refute text =~ "canceled"
    end

    test "reports the hold when it outlasts the interval" do
      charger = %{@charger | last_converted_at: ~N[2026-10-18 10:30:00]}
      blocked = {:canceled, hold_until(~N[2026-10-18 15:00:00])}
      assert EnkephalinSchedule.next_charge(@now, charger, blocked) == ~N[2026-10-18 15:00:00]
      text = EnkephalinSchedule.outlook(@now, charger, blocked, false)
      assert text =~ "a run was canceled recently"
      refute text =~ "interval since the last charge"
    end

    test "says nothing when off, and defers to a running job" do
      assert EnkephalinSchedule.outlook(@now, %{@charger | enabled: false}, nil, false) == nil
      assert EnkephalinSchedule.outlook(@now, @charger, nil, true) =~ "Waiting for the current run to finish before charging"
    end
  end

  describe "label" do
    test "shows whichever scheduler acts first" do
      assert Overview.label(@now, @runs, @pending, @charger, nil, false) == "Runs in 1h"
      assert Overview.label(@now, @runs, @done, @charger, nil, false) == "Charge in 2h"
      assert Overview.label(@now, @runs, @done, %{@charger | enabled: false}, nil, false) == "done today"
      assert Overview.label(@now, %{@runs | enabled: false}, @pending, %{@charger | enabled: false}, nil, false) == "off"
      assert Overview.label(@now, @runs, @pending, @charger, nil, true) == "busy now"
    end

    test "says held while a hold or cancel cooldown is active" do
      assert Overview.label(@now, @runs, @pending, @charger, {:hold, DateTime.add(@later, 3600)}, false) =~ ~r/^held until /
    end
  end

  test "a hold or cancel blocks both through the shared Scheduler.blocked" do
    :ok = Scheduler.hold("2")
    assert {:hold, _} = Scheduler.blocked()
  end
end
