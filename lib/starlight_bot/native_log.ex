defmodule StarlightBot.NativeLog do
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ok = StarlightBot.Native.init_logger(self())
    {:ok, nil}
  end

  @impl true
  def handle_info({:native_log, level, message}, state) do
    Logger.log(level, message, domain: [:native])
    {:noreply, state}
  end
end
