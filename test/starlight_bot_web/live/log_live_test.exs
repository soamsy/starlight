defmodule StarlightBotWeb.Live.LogLiveTest do
  use ExUnit.Case, async: false

  import StarlightBot.Navigation.DSL

  alias StarlightBot.{Ctx, FakeWorld, LogStore}
  alias StarlightBot.Navigation.Runner
  alias StarlightBotWeb.Live.LogLive

  @moduletag :capture_log

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  defp html(socket) do
    socket.assigns
    |> LogLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "renders existing lines with timestamps and appends live ones" do
    marker = "log-live-#{System.unique_integer([:positive])}"
    LogStore.append(:error, "#{marker} boom")
    :sys.get_state(LogStore)

    {:ok, socket} = LogLive.mount(%{}, %{}, socket())
    rendered = html(socket)
    assert rendered =~ "#{marker} boom"
    assert rendered =~ ~r/\d\d:\d\d:\d\d\.\d{3}/

    entry = %{seq: 999_999_999, at: LogStore.now(), kind: :ok, text: "#{marker} live"}
    {:noreply, socket} = LogLive.handle_info({:log_entry, entry}, socket)
    assert html(socket) =~ "#{marker} live"
  end

  def nested_wait(_frame, ctx), do: Runner.run_steps([await(:fw_done, timeout: 5_000)], ctx)

  test "the machines panel shows running machines nested under their parents, and forgets them when done" do
    FakeWorld.start!(hooks: [:fw_done])
    run = Task.async(fn -> Runner.run_steps([call(__MODULE__, :nested_wait)], Ctx.new()) end)
    Process.sleep(300)

    {:ok, socket} = LogLive.mount(%{}, %{}, socket())
    {:noreply, socket} = LogLive.handle_info(:refresh_machines, socket)
    rows = Enum.take(socket.assigns.machines, -2)

    assert [%{depth: depth, current: outer}, %{depth: inner_depth, state: :polling, waiting: waiting}] = rows
    assert outer =~ "nested_wait"
    assert inner_depth == depth + 1
    assert waiting =~ "await :fw_done"
    assert html(socket) =~ "await :fw_done"

    FakeWorld.show(:fw_done)
    assert {:ok, _} = Task.await(run)

    {:noreply, socket} = LogLive.handle_info(:refresh_machines, socket)
    refute Enum.any?(socket.assigns.machines, &(&1.waiting && &1.waiting =~ "fw_done"))
  end
end
