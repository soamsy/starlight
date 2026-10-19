defmodule StarlightBotWeb.Live.LogLiveTest do
  use ExUnit.Case, async: false

  alias StarlightBot.LogStore
  alias StarlightBotWeb.Live.LogLive

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
end
