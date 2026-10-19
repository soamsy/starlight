defmodule StarlightBot.Navigation.SettleFallbackTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Navigation.Runner

  test "parent-only fallbacks are the no-identity refinements" do
    assert Runner.fallback_screen?(:lux_unknown)
    assert Runner.fallback_screen?(:home_unknown)
    refute Runner.fallback_screen?(:lux_thread)
    refute Runner.fallback_screen?(:battle_turn_or_over)
  end

  test "a fallback waits for the real screen to show up" do
    assert Runner.settle_fallback({:ok, :lux_unknown}, fn -> {:ok, :lux_thread} end) == {:ok, :lux_thread}
  end

  test "a concrete screen is accepted without rechecking" do
    assert Runner.settle_fallback({:ok, :lux_exp}, fn -> flunk("rechecked") end) == {:ok, :lux_exp}
  end

  test "a fallback that never settles is accepted at the deadline" do
    deadline = System.monotonic_time(:millisecond) + 250
    assert Runner.settle_fallback({:ok, :lux_unknown}, fn -> :unknown end, deadline) == {:ok, :lux_unknown}
  end
end
