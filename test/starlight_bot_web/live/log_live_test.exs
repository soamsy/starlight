defmodule StarlightBotWeb.Live.LogLiveTest do
  use ExUnit.Case, async: false

  alias StarlightBot.LogStore
  alias StarlightBotWeb.Live.LogLive

  @moduletag :capture_log

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  defp settle(socket) do
    streams = Map.update!(socket.assigns.streams, :entries, &Phoenix.LiveView.LiveStream.prune/1)
    %{socket | assigns: %{socket.assigns | streams: streams}}
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

  test "step lines are hidden until steps are switched on, and errors only narrows to errors" do
    marker = "log-kinds-#{System.unique_integer([:positive])}"
    LogStore.append(:step, "#{marker} step")
    LogStore.append(:info, "#{marker} info")
    LogStore.append(:error, "#{marker} error")
    :sys.get_state(LogStore)

    {:ok, socket} = LogLive.mount(%{}, %{}, socket())
    rendered = html(socket)
    refute rendered =~ "#{marker} step"
    assert rendered =~ "#{marker} info"

    {:noreply, socket} = LogLive.handle_event("toggle_steps", %{}, settle(socket))
    assert html(socket) =~ "#{marker} step"

    {:noreply, socket} = LogLive.handle_event("toggle_errors", %{}, settle(socket))
    rendered = html(socket)
    assert rendered =~ "#{marker} error"
    refute rendered =~ "#{marker} info"

    {:noreply, socket} = LogLive.handle_info({:log_entry, %{seq: 999_999_998, at: LogStore.now(), kind: :info, text: "#{marker} live info"}}, settle(socket))
    refute html(socket) =~ "#{marker} live info"
  end

  test "embedded in another page it keeps only its line cap and drops the page-only controls" do
    marker = "log-embedded-#{System.unique_integer([:positive])}"
    for n <- 1..5, do: LogStore.append(:info, "#{marker} #{n}")
    :sys.get_state(LogStore)

    {:ok, socket} = LogLive.mount(%{}, %{"max_lines" => 3}, socket())
    rendered = html(socket)
    assert socket.assigns.shown == 3
    assert rendered =~ "#{marker} 5"
    refute rendered =~ "#{marker} 2"
    assert :binary.match(rendered, "#{marker} 3") < :binary.match(rendered, "#{marker} 5")
    refute rendered =~ ">Log</h2>"
    refute rendered =~ "Load older"

    entry = %{seq: 999_999_997, at: LogStore.now(), kind: :info, text: "#{marker} live", lineage: []}
    {:noreply, socket} = LogLive.handle_info({:log_entry, entry}, settle(socket))
    assert socket.assigns.shown == 3
    assert html(socket) =~ "#{marker} live"
  end
end
