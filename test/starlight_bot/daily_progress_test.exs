defmodule StarlightBot.DailyProgressTest do
  use ExUnit.Case, async: true

  alias StarlightBot.DailyProgress

  @settings %{exp_waves: 5, thread_waves: 3, md_runs: 2}

  setup do
    :ok = StarlightBot.TestDB.checkout()
  end

  test "completions count from 9 PM UTC and not before" do
    before_reset = ~U[2026-10-18 20:59:59Z]
    after_reset = ~U[2026-10-18 21:00:00Z]

    DailyProgress.record("exp", 4, before_reset)
    DailyProgress.record("exp", 2, after_reset)
    DailyProgress.record("thread", 3, ~U[2026-10-19 08:00:00Z])
    DailyProgress.record("md", 1, ~U[2026-10-19 20:00:00Z])

    now = ~U[2026-10-19 20:30:00Z]
    assert DailyProgress.completed(now) == %{"exp" => 2, "thread" => 3, "md" => 1}
    assert DailyProgress.remaining(@settings, now) == %{"exp" => 3, "thread" => 0, "md" => 1}
    assert DailyProgress.pending?(DailyProgress.remaining(@settings, now))

    next_day = ~U[2026-10-19 21:00:00Z]
    assert DailyProgress.completed(next_day) == %{"exp" => 0, "thread" => 0, "md" => 0}
  end

  test "remaining never goes negative and nothing is pending once targets are met" do
    DailyProgress.record("exp", 9, ~U[2026-10-19 08:00:00Z])
    remaining = DailyProgress.remaining(%{exp_waves: 5, thread_waves: 0, md_runs: 0}, ~U[2026-10-19 09:00:00Z])
    assert remaining == %{"exp" => 0, "thread" => 0, "md" => 0}
    refute DailyProgress.pending?(remaining)
  end
end
