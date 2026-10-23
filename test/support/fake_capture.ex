defmodule StarlightBot.FakeCapture do
  use GenServer

  def start_link(focused?), do: GenServer.start_link(__MODULE__, focused?, name: StarlightBot.Vision.Capture)

  @impl true
  def init(focused?), do: {:ok, focused?}

  @impl true
  def handle_call(:focused?, _from, focused?), do: {:reply, focused?, focused?}
  def handle_call(:grab_frame, _from, focused?), do: {:reply, {:error, :no_window}, focused?}
  def handle_call(:window_rect, _from, focused?), do: {:reply, nil, focused?}
end
