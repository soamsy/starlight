defmodule StarlightBot.EnkephalinScheduleTest do
  use ExUnit.Case, async: false

  alias StarlightBot.EnkephalinSchedule

  @settings %{window_start: "09:00", window_end: "13:00", interval_minutes: 120, last_converted_at: nil}

  describe "launch ownership" do
    @on %{close_game_after_charge: true}
    @idle %{enabled: false}
    @done %{"exp" => 0, "thread" => 0, "md" => 0}

    setup do
      :ok = StarlightBot.TestDB.checkout()
      EnkephalinSchedule.release()
      on_exit(fn -> :persistent_term.put({EnkephalinSchedule, :ownership}, nil) end)
    end

    test "any intervention after the launch ends ownership" do
      EnkephalinSchedule.own_launch()
      assert EnkephalinSchedule.owned?()
      EnkephalinSchedule.revoke(:hold)
      refute EnkephalinSchedule.owned?()
      assert {:revoked, :hold} = EnkephalinSchedule.ownership()
    end

    test "revoking a game the bot did not launch changes nothing" do
      EnkephalinSchedule.revoke(:hold)
      assert EnkephalinSchedule.ownership() == nil
    end

    test "the next launch takes ownership back" do
      EnkephalinSchedule.own_launch()
      EnkephalinSchedule.revoke(:cancel)
      EnkephalinSchedule.own_launch()
      assert EnkephalinSchedule.owned?()
    end

    test "the close note says whether the game will be closed and why not" do
      assert EnkephalinSchedule.close_note(@on, @idle, @done) =~ "already open"
      EnkephalinSchedule.own_launch()
      assert EnkephalinSchedule.close_note(@on, @idle, @done) =~ "Will close"
      assert EnkephalinSchedule.close_note(@on, %{enabled: true}, %{@done | "exp" => 2}) =~ "goals are still pending"
      assert EnkephalinSchedule.close_note(%{close_game_after_charge: false}, @idle, @done) =~ "closing is off"
      EnkephalinSchedule.revoke(:pause)
      assert EnkephalinSchedule.close_note(@on, @idle, @done) =~ "a run was paused"
    end
  end

  describe "close_game_after_charge" do
    setup do
      :ok = StarlightBot.TestDB.checkout()
    end

    test "is stored, read back, and kept by set_enabled" do
      refute EnkephalinSchedule.get_settings().close_game_after_charge

      attrs = EnkephalinSchedule.get_settings() |> Map.put(:close_game_after_charge, true)
      assert {:ok, %{close_game_after_charge: true}} = EnkephalinSchedule.save_settings(attrs)
      assert {:ok, %{close_game_after_charge: true, enabled: true}} = EnkephalinSchedule.set_enabled(true)
      assert {:ok, %{close_game_after_charge: false}} = EnkephalinSchedule.save_settings(%{attrs | close_game_after_charge: false})
    end
  end

  describe "close_after_charge?" do
    @on %{close_game_after_charge: true}
    @clean %{kind: :enkephalin, ok?: true}
    @done %{"exp" => 0, "thread" => 0, "md" => 0}
    @pending %{"exp" => 2, "thread" => 0, "md" => 0}

    test "closes after a clean charge" do
      assert EnkephalinSchedule.close_after_charge?(@on, %{enabled: true}, @done, @clean)
      assert EnkephalinSchedule.close_after_charge?(@on, %{enabled: false}, @pending, @clean)
    end

    test "never closes with the setting off" do
      refute EnkephalinSchedule.close_after_charge?(%{close_game_after_charge: false}, %{enabled: false}, @done, @clean)
    end

    test "does not close after a cancelled, failed or different run" do
      refute EnkephalinSchedule.close_after_charge?(@on, %{enabled: false}, @done, nil)
      refute EnkephalinSchedule.close_after_charge?(@on, %{enabled: false}, @done, %{kind: :enkephalin, ok?: false})
      refute EnkephalinSchedule.close_after_charge?(@on, %{enabled: false}, @done, %{kind: :mirror_dungeon, ok?: true})
    end

    test "leaves the game open when the goals scheduler still has work to relaunch for" do
      refute EnkephalinSchedule.close_after_charge?(@on, %{enabled: true}, @pending, @clean)
    end
  end

  test "due only inside the window and once the interval has passed" do
    assert EnkephalinSchedule.due?(~N[2026-10-18 09:00:00], @settings)
    refute EnkephalinSchedule.due?(~N[2026-10-18 08:59:59], @settings)
    refute EnkephalinSchedule.due?(~N[2026-10-18 13:00:00], @settings)

    recent = %{@settings | last_converted_at: ~N[2026-10-18 09:30:00]}
    refute EnkephalinSchedule.due?(~N[2026-10-18 11:29:59], recent)
    assert EnkephalinSchedule.due?(~N[2026-10-18 11:30:00], recent)
  end

  test "the first charge of every window ignores the interval since the last window's charge" do
    settings = %{window_start: "05:00", window_end: "01:00", interval_minutes: 540, last_converted_at: ~N[2026-10-18 23:00:00]}

    assert EnkephalinSchedule.due?(~N[2026-10-19 05:00:00], settings)
    assert EnkephalinSchedule.next_charge(~N[2026-10-19 01:30:00], settings, nil) == ~N[2026-10-19 05:00:00]
  end

  test "an overnight window stays open past midnight" do
    settings = %{@settings | window_start: "22:00", window_end: "04:00"}

    assert EnkephalinSchedule.due?(~N[2026-10-19 03:59:00], settings)
    refute EnkephalinSchedule.due?(~N[2026-10-19 04:00:00], settings)
  end

  test "day timeline lists charges from the window start every interval and splits overnight windows" do
    assert %{windows: [{480, 1320}], charges: [480, 840, 1200]} = EnkephalinSchedule.day_timeline("08:00", "22:00", 6)
    assert %{windows: [{0, 240}, {1320, 1440}], charges: [0, 120, 1320]} = EnkephalinSchedule.day_timeline("22:00", "04:00", 2)
    assert %{spans: [%{from: 0, to: 480, gap_minutes: 720, modules: 6}, %{from: 480, to: 840, gap_minutes: 360, modules: 3} | _]} = EnkephalinSchedule.day_timeline("08:00", "22:00", 6)
    assert EnkephalinSchedule.day_timeline("", "22:00", 6) == nil
    assert EnkephalinSchedule.day_timeline("08:00", "08:00", 6) == nil
  end

  test "a window with a 9h interval charges at 5, 14 and 23 every day for 12 modules in total" do
    assert %{spans: [%{modules: 3}, %{modules: 4}, %{modules: 4}]} = EnkephalinSchedule.day_timeline("05:00", "01:00", 9)
  end

  test "modules per charge follow 10 enkephalin an hour, 20 per module, capped at 160 enkephalin" do
    assert %{generated: 20, banked: 20, capped?: false, modules: 1} = EnkephalinSchedule.modules_for_minutes(120)
    assert %{generated: 60, modules: 3, leftover: 0} = EnkephalinSchedule.modules_for_minutes(360)
    assert %{generated: 30, modules: 1, leftover: 10} = EnkephalinSchedule.modules_for_minutes(180)
    assert %{generated: 160, capped?: false, modules: 8} = EnkephalinSchedule.modules_for_minutes(960)
    assert %{generated: 240, banked: 160, capped?: true, modules: 8} = EnkephalinSchedule.modules_for_minutes(1440)
  end
end
