defmodule StarlightBot.EnkephalinScheduleTest do
  use ExUnit.Case, async: true

  alias StarlightBot.EnkephalinSchedule

  @settings %{window_start: "09:00", window_end: "13:00", interval_minutes: 120, last_converted_at: nil}

  test "due only inside the window and once the interval has passed" do
    assert EnkephalinSchedule.due?(~N[2026-10-18 09:00:00], @settings)
    refute EnkephalinSchedule.due?(~N[2026-10-18 08:59:59], @settings)
    refute EnkephalinSchedule.due?(~N[2026-10-18 13:00:00], @settings)

    recent = %{@settings | last_converted_at: ~N[2026-10-18 09:30:00]}
    refute EnkephalinSchedule.due?(~N[2026-10-18 11:29:59], recent)
    assert EnkephalinSchedule.due?(~N[2026-10-18 11:30:00], recent)
  end

  test "an overnight window stays open past midnight" do
    settings = %{@settings | window_start: "22:00", window_end: "04:00"}

    assert EnkephalinSchedule.due?(~N[2026-10-19 03:59:00], settings)
    refute EnkephalinSchedule.due?(~N[2026-10-19 04:00:00], settings)
  end

  test "day timeline lists charges from the window start every interval and splits overnight windows" do
    assert %{windows: [{480, 1320}], charges: [480, 840, 1200]} = EnkephalinSchedule.day_timeline("08:00", "22:00", 6)
    assert %{windows: [{0, 240}, {1320, 1440}], charges: [0, 120, 1320]} = EnkephalinSchedule.day_timeline("22:00", "04:00", 2)
    assert EnkephalinSchedule.day_timeline("", "22:00", 6) == nil
    assert EnkephalinSchedule.day_timeline("08:00", "08:00", 6) == nil
  end

  test "modules per charge follow 10 enkephalin an hour, 20 per module, capped at 160 enkephalin" do
    assert %{generated: 20, banked: 20, capped?: false, modules: 1} = EnkephalinSchedule.modules_per_charge(2)
    assert %{generated: 60, modules: 3, leftover: 0} = EnkephalinSchedule.modules_per_charge(6)
    assert %{generated: 30, modules: 1, leftover: 10} = EnkephalinSchedule.modules_per_charge(3)
    assert %{generated: 160, capped?: false, modules: 8} = EnkephalinSchedule.modules_per_charge(16)
    assert %{generated: 240, banked: 160, capped?: true, modules: 8} = EnkephalinSchedule.modules_per_charge(24)
  end
end
