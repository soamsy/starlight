defmodule StarlightBot.Vision.FrameHistory do
  use GenServer

  alias StarlightBot.Vision.{Capture, Frame, ImageB64}

  @capacity 50
  @interval_ms 150
  @display_every 1

  def start_link(opts) do
    gen_opts = if Keyword.get(opts, :name, __MODULE__), do: [name: Keyword.get(opts, :name, __MODULE__)], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def capacity, do: @capacity

  def start_capture(owner, server \\ __MODULE__), do: GenServer.call(server, {:start, owner})
  def stop_capture(server \\ __MODULE__), do: GenServer.call(server, :stop)
  def bounds(server \\ __MODULE__), do: GenServer.call(server, :bounds)

  def get(id, server \\ __MODULE__) do
    case GenServer.call(server, {:get, id}) do
      {:ok, binary, window_rect} -> {:ok, Frame.from_capture(binary, window_rect)}
      :error -> :error
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       grab: Keyword.get(opts, :grab, &Capture.grab_frame/0),
       interval: Keyword.get(opts, :interval_ms, @interval_ms),
       owner: nil,
       monitor: nil,
       token: nil,
       entries: %{},
       first: 1,
       last: 0
     }}
  end

  @impl true
  def handle_call({:start, owner}, _from, state) do
    state = state |> halt() |> release_owner() |> Map.merge(%{entries: %{}, first: 1, last: 0})
    token = make_ref()
    send(self(), {:tick, token})
    {:reply, :ok, %{state | owner: owner, monitor: Process.monitor(owner), token: token}}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, halt(state)}

  def handle_call(:bounds, _from, %{last: 0} = state), do: {:reply, nil, state}
  def handle_call(:bounds, _from, state), do: {:reply, {state.first, state.last}, state}

  def handle_call({:get, id}, _from, state) do
    case state.entries do
      %{^id => {binary, window_rect}} -> {:reply, {:ok, binary, window_rect}, state}
      _ -> {:reply, :error, state}
    end
  end

  @impl true
  def handle_info({:tick, token}, %{token: token} = state) do
    case state.grab.() do
      {:ok, frame} ->
        state = push(state, frame)
        notify(state, frame)
        {:noreply, %{state | token: schedule(state, token)}}

      {:error, reason} ->
        send(state.owner, {:frame_history, :error, reason})
        {:noreply, halt(state)}
    end
  end

  def handle_info({:tick, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    {:noreply, %{halt(state) | owner: nil, monitor: nil, entries: %{}, first: 1, last: 0}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp push(state, frame) do
    id = state.last + 1
    entries = Map.put(state.entries, id, {frame.binary, frame.window_rect})
    first = max(state.first, id - @capacity + 1)
    entries = if first > state.first, do: Map.delete(entries, state.first), else: entries
    %{state | entries: entries, first: first, last: id}
  end

  defp notify(state, frame) do
    jpeg = if frame.mat && rem(state.last, @display_every) == 0, do: ImageB64.jpeg(frame.mat)
    send(state.owner, {:frame_history, :tick, state.first, state.last, jpeg})
  end

  defp schedule(state, token) do
    Process.send_after(self(), {:tick, token}, state.interval)
    token
  end

  defp halt(state), do: %{state | token: nil}

  defp release_owner(%{monitor: nil} = state), do: state

  defp release_owner(state) do
    Process.demonitor(state.monitor, [:flush])
    %{state | monitor: nil, owner: nil}
  end
end
