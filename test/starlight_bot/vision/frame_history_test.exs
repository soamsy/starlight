defmodule StarlightBot.Vision.FrameHistoryTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Vision.{Frame, FrameHistory}

  setup do
    binary = :binary.copy(<<0>>, 1920 * 1080 * 3)
    grab = fn -> {:ok, %Frame{binary: binary, window_rect: {0, 0, 1920, 1080}}} end

    pid = start_supervised!({FrameHistory, name: nil, grab: grab, interval_ms: 1})
    %{server: pid}
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end

  test "keeps only the newest 100 frames with contiguous ids", %{server: server} do
    :ok = FrameHistory.start_capture(self(), server)
    wait_until(fn -> match?({_, last} when last >= 80, FrameHistory.bounds(server)) end)
    :ok = FrameHistory.stop_capture(server)

    {first, last} = FrameHistory.bounds(server)
    assert last - first + 1 == FrameHistory.capacity()
    assert {:ok, %Frame{}} = FrameHistory.get(first, server)
    assert :error = FrameHistory.get(first - 1, server)
    assert :error = FrameHistory.get(last + 1, server)
  end

  test "stop keeps the buffer and halts capture", %{server: server} do
    :ok = FrameHistory.start_capture(self(), server)
    wait_until(fn -> FrameHistory.bounds(server) != nil end)
    :ok = FrameHistory.stop_capture(server)
    bounds = FrameHistory.bounds(server)
    Process.sleep(30)
    assert FrameHistory.bounds(server) == bounds
  end

  test "owner exit clears the buffer", %{server: server} do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    :ok = FrameHistory.start_capture(owner, server)
    wait_until(fn -> FrameHistory.bounds(server) != nil end)
    Process.exit(owner, :kill)
    wait_until(fn -> FrameHistory.bounds(server) == nil end)
  end

  test "grab error stops capture and notifies the owner" do
    pid = start_supervised!({FrameHistory, name: nil, grab: fn -> {:error, :no_window} end}, id: :failing)
    :ok = FrameHistory.start_capture(self(), pid)
    assert_receive {:frame_history, :error, :no_window}, 500
  end
end
