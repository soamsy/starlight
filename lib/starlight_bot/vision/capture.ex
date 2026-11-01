defmodule StarlightBot.Vision.Capture do
  use GenServer
  require Logger
  alias StarlightBot.{Native, Vision.Frame}

  @refresh_interval_ms 2_000
  @topic "capture:window_rect"
  @max_refresh_interval_ms 30_000

  defstruct [:window_title, :window_class, :window_rect, :refresh_interval_ms]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def grab_frame do
    GenServer.call(__MODULE__, :grab_frame, 5_000)
  end

  def grab_regions(rects) do
    GenServer.call(__MODULE__, {:grab_regions, rects}, 5_000)
  end

  def window_rect do
    GenServer.call(__MODULE__, :window_rect, 5_000)
  end

  def refresh_window_rect do
    GenServer.cast(__MODULE__, :refresh_window_rect)
  end

  def focused? do
    GenServer.call(__MODULE__, :focused?, 5_000)
  end

  def grab_region({_rx, _ry, _rw, _rh} = region) do
    GenServer.call(__MODULE__, {:grab_region, region}, 5_000)
  end

  def save_screenshot(path) do
    GenServer.call(__MODULE__, {:save_screenshot, path}, 10_000)
  end

  @impl true
  def init(_opts) do
    window_title = Application.get_env(:starlight_bot, :game_window_title, "LimbusCompany")
    window_class = Application.get_env(:starlight_bot, :game_window_class, "LimbusCompany")
    Logger.info("Vision.Capture starting (window: #{window_title})", module: __MODULE__)

    state = %__MODULE__{
      window_title: window_title,
      window_class: window_class,
      window_rect: nil,
      refresh_interval_ms: @refresh_interval_ms,
    }

    state = case query_window_rect(state) do
      {:ok, s} ->
        Logger.info("Window found: #{inspect(s.window_rect)}", module: __MODULE__)
        s
      {:error, :window_not_found} ->
        Logger.warning("Game window not found — start Limbus Company to enable capture",
          module: __MODULE__)
        state
      {:error, reason} ->
        Logger.warning("Window rect query failed: #{inspect(reason)}", module: __MODULE__)
        state
    end

    schedule_refresh(state.refresh_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:grab_frame, _from, state) do
    state = ensure_window_rect(state)

    case state.window_rect do
      nil ->
        {:reply, {:error, :no_window}, state}

      window_rect ->
        case Native.grab_frame(state.window_title) do
          {:ok, binary, _w, _h} ->
            frame = Frame.from_capture(binary, window_rect)
            {:reply, {:ok, frame}, state}

          {:error, reason} = err ->
            Logger.warning("grab_frame failed: #{inspect(reason)}", module: __MODULE__)
            {:reply, err, state}
        end
    end
  end

  @impl true
  def handle_call({:grab_regions, rects}, _from, state) do
    state = ensure_window_rect(state)

    case state.window_rect do
      nil ->
        {:reply, {:error, :no_window}, state}

      window_rect ->
        case Native.grab_regions(state.window_title, rects) do
          {:ok, binaries} ->
            patches =
              Enum.zip_with(rects, binaries, fn {_x, _y, w, h} = rect, binary ->
                {rect, binary |> Evision.Mat.from_binary({:u, 8}, h, w, 3) |> Evision.Mat.clone()}
              end)

            {:reply, {:ok, Frame.from_patches(patches, window_rect)}, state}

          {:error, reason} = err ->
            Logger.warning("grab_regions failed: #{inspect(reason)}", module: __MODULE__)
            {:reply, err, state}
        end
    end
  end

  @impl true
  def handle_call(:window_rect, _from, state) do
    state = ensure_window_rect(state)
    {:reply, state.window_rect, state}
  end

  @impl true
  def handle_call(:focused?, _from, state) do
    focused? =
      case Native.is_window_focused(state.window_class) do
        {:ok, focused?} -> focused?
        {:error, _} -> false
      end

    {:reply, focused?, state}
  end

  @impl true
  def handle_call({:grab_region, {rx, ry, rw, rh}}, _from, state) do
    state = ensure_window_rect(state)
    case state.window_rect do
      nil ->
        {:reply, {:error, :no_window}, state}
      _ ->
        case Native.grab_frame_region(state.window_title, rx, ry, rw, rh) do
          {:ok, binary, w, h} ->
            mat = Evision.Mat.from_binary(binary, {:u, 8}, h, w, 3)
            {:reply, {:ok, mat}, state}
          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  @impl true
  def handle_call({:save_screenshot, path}, _from, state) do
    state = ensure_window_rect(state)

    result =
      with {:ok, _window_rect} <- maybe_rect(state),
           {:ok, binary, w, h} <- Native.grab_frame(state.window_title) do
        Native.save_png(binary, w, h, path)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast(:refresh_window_rect, state) do
    {:noreply, do_refresh_rect(state)}
  end

  @impl true
  def handle_info(:refresh_window_rect_tick, state) do
    state = do_refresh_rect(state)
    schedule_refresh(state.refresh_interval_ms)
    {:noreply, state}
  end

  defp schedule_refresh(interval_ms) do
    Process.send_after(self(), :refresh_window_rect_tick, interval_ms)
  end

  defp do_refresh_rect(state) do
    case query_window_rect(state) do
      {:ok, s} ->
        Logger.debug("Window rect refreshed: #{inspect(s.window_rect)}", module: __MODULE__)
        %{s | refresh_interval_ms: @refresh_interval_ms}

      {:error, reason} ->
        if state.window_rect do
          Logger.warning("Window rect refresh failed: #{inspect(reason)}", module: __MODULE__)
        end

        next_interval = min(state.refresh_interval_ms * 2, @max_refresh_interval_ms)
        %{put_rect(state, nil) | refresh_interval_ms: next_interval}
    end
  end

  defp ensure_window_rect(%{window_rect: nil} = state) do
    case query_window_rect(state) do
      {:ok, s} -> s
      _ -> state
    end
  end
  defp ensure_window_rect(state), do: state

  defp query_window_rect(state) do
    case Native.get_window_rect(state.window_class) do
      {:ok, wx, wy, w, h} -> {:ok, put_rect(state, {wx, wy, w, h})}
      err -> err
    end
  end

  defp put_rect(%{window_rect: rect} = state, rect), do: state
  defp put_rect(state, rect) do
    Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, {:window_rect, rect})
    %{state | window_rect: rect}
  end

  defp maybe_rect(%{window_rect: nil}), do: {:error, :no_window}
  defp maybe_rect(%{window_rect: r}), do: {:ok, r}
end
