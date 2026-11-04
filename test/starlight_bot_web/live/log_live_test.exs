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

  defp pushed(socket) do
    socket.private.live_temp
    |> Map.get(:push_events, [])
    |> Enum.reverse()
    |> Enum.map(fn [_event, payload] -> payload end)
  end

  defp texts(socket), do: socket |> pushed() |> Enum.flat_map(& &1.entries) |> Enum.map(&Enum.at(&1, 3))

  defp ready(session \\ %{}) do
    {:ok, socket} = LogLive.mount(%{}, session, socket())
    {:noreply, socket} = LogLive.handle_event("log_ready", %{}, socket)
    socket
  end

  test "sends existing lines on ready, then batches live ones" do
    marker = "log-live-#{System.unique_integer([:positive])}"
    LogStore.append(:error, "#{marker} boom")
    :sys.get_state(LogStore)

    socket = ready()
    assert [%{mode: "reset", entries: entries}] = pushed(socket)
    assert Enum.any?(entries, &(Enum.at(&1, 3) == "#{marker} boom"))
    assert Enum.any?(entries, &(Enum.at(&1, 1) =~ ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}$/))

    entry = %{seq: 999_999_999, at: LogStore.now(), kind: :ok, text: "#{marker} live", lineage: []}
    {:noreply, socket} = LogLive.handle_info({:log_entry, entry}, socket)
    {:noreply, socket} = LogLive.handle_info({:log_entry, %{entry | seq: 1_000_000_000, text: "#{marker} live 2"}}, socket)
    {:noreply, socket} = LogLive.handle_info(:flush_entries, socket)
    assert %{mode: "append", entries: [[999_999_999, _, "ok", _, []], [1_000_000_000, _, "ok", _, []]]} = List.last(pushed(socket))
  end

  test "entries already sent in the reset are not sent again" do
    marker = "log-dupe-#{System.unique_integer([:positive])}"
    LogStore.append(:info, "#{marker} one")
    :sys.get_state(LogStore)

    socket = ready()
    [newest] = LogStore.recent(1)
    {:noreply, socket} = LogLive.handle_info({:log_entry, newest}, socket)
    assert socket.assigns.pending == []
  end

  test "filter toggles only change assigns and never resend lines" do
    socket = ready()
    sent = length(pushed(socket))

    {:noreply, socket} = LogLive.handle_event("toggle_steps", %{}, socket)
    {:noreply, socket} = LogLive.handle_event("toggle_errors", %{}, socket)
    assert socket.assigns.show_steps
    assert socket.assigns.errors_only
    assert length(pushed(socket)) == sent
  end

  test "embedded in another page it sends every line and drops the page-only controls" do
    marker = "log-embedded-#{System.unique_integer([:positive])}"
    for n <- 1..5, do: LogStore.append(:info, "#{marker} #{n}")
    :sys.get_state(LogStore)

    socket = ready(%{"embedded" => true})
    sent = Enum.filter(texts(socket), &String.starts_with?(&1, marker))
    assert sent == for(n <- 1..5, do: "#{marker} #{n}")
    assert socket.assigns.embedded?

    {:noreply, socket} = LogLive.handle_info({:nav_state, %{}}, socket)
    assert socket.assigns.embedded?
  end
end
