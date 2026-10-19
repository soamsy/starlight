defmodule StarlightBot.Navigation.RunClockTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Navigation.RunClock

  test "only counts time between start and stop, across pauses" do
    clock = RunClock.start(1_000)
    assert RunClock.running?(clock)
    assert RunClock.elapsed_ms(clock, 4_000) == 3_000

    paused = RunClock.stop(clock, 5_000)
    refute RunClock.running?(paused)
    assert RunClock.elapsed_ms(paused, 60_000) == 4_000

    resumed = RunClock.start(paused, 60_000)
    assert RunClock.elapsed_ms(resumed, 62_500) == 6_500
  end

  test "stopping twice or starting twice doesn't double count" do
    clock = RunClock.start(0) |> RunClock.start(500) |> RunClock.stop(1_000) |> RunClock.stop(9_000)
    assert RunClock.elapsed_ms(clock, 20_000) == 1_000
  end
end
