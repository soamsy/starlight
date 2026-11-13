defmodule StarlightBot.Navigation.SettleFallbackTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Navigation.Runner

  defmodule DwellStub do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: StarlightBot.Input.Mouse)
    def init(state), do: {:ok, state}
    def handle_call({:dwell, _ms, _opts}, _from, state), do: {:reply, {0, 0}, state}
  end

  setup do
    start_supervised!(DwellStub)
    :ok
  end

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
