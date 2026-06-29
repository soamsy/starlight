defmodule StarlightBotWeb.Live.ScreenshotViewerLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.{Hooks, Native, Vision.Capture, Vision.Frame, Vision.HookRegistry, Vision.Matcher}

  @max_frames 40
  @tick_ms 500
  @handoff_path "/tmp/_starlight_hook_handoff.jpg"
  @thumb_w 192
  @thumb_h 108

  @impl true
  def mount(_params, _session, socket) do
    base = "/tmp/_starlight_sv_#{System.unique_integer([:positive])}"
    if connected?(socket), do: schedule_tick()

    cache_status =
      case Native.cache_age_ms() do
        {:ok, _} -> :running
        _ -> :stopped
      end

    {:ok,
     socket
     |> assign(:frames, [])
     |> assign(:selected_id, nil)
     |> assign(:running, true)
     |> assign(:frame_counter, 0)
     |> assign(:cache_age_ms, nil)
     |> assign(:status, :waiting)
     |> assign(:cache_status, cache_status)
     |> assign(:current_frame, nil)
     |> assign(:current_full_b64, nil)
     |> assign(:base, base)
     |> assign(:tmp_thumb, base <> ".thumb.jpg")
     |> assign(:tmp_region, base <> ".region.jpg")
     |> assign(:tmp_template, base <> ".template.jpg")
     |> assign(:focused_hook, nil)
     |> assign(:focused_hook_template_b64, nil)
     |> assign(:all_hooks, Hooks.list_hooks())
     |> assign(:selected_hooks, MapSet.new())
     |> assign(:hook_results, %{})
     |> assign(:hook_filter, "")
     |> assign(:max_frames, @max_frames)}
  end

  @impl true
  def handle_event("start_cache", _, socket) do
    viewer = self()
    Task.start(fn -> send(viewer, {:cache_start_result, Capture.start_cache()}) end)
    {:noreply, assign(socket, :cache_status, :starting)}
  end

  @impl true
  def handle_event("stop_cache", _, socket) do
    Capture.stop_cache()
    {:noreply, assign(socket, :cache_status, :stopped)}
  end

  @impl true
  def handle_event("send_to_hook_editor", _, socket) do
    case socket.assigns.current_frame && get_full_path(socket.assigns.current_frame.id) do
      nil ->
        {:noreply, put_flash(socket, :error, "No frame available.")}

      path ->
        File.cp!(path, @handoff_path)
        {:noreply, push_navigate(socket, to: "/hooks?from_cache=1")}
    end
  rescue
    _ -> {:noreply, put_flash(socket, :error, "Failed to prepare frame for hook editor.")}
  end

  @impl true
  def handle_event("toggle_running", _, socket) do
    running = !socket.assigns.running
    if running, do: schedule_tick()
    {:noreply, assign(socket, :running, running)}
  end

  @impl true
  def handle_event("select_frame", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    {:noreply, socket |> assign(:selected_id, id) |> put_current_frame()}
  end

  @impl true
  def handle_event("select_latest", _, socket) do
    {:noreply, socket |> assign(:selected_id, nil) |> put_current_frame()}
  end

  @impl true
  def handle_event("select_hook_cell", %{"id" => id_str, "hook" => hook_name}, socket) do
    id = String.to_integer(id_str)
    template_b64 = encode_template(hook_name, socket.assigns.tmp_template)

    {:noreply,
     socket
     |> assign(:selected_id, id)
     |> assign(:focused_hook, hook_name)
     |> assign(:focused_hook_template_b64, template_b64)
     |> put_current_frame()}
  end

  @impl true
  def handle_event("clear_focused_hook", _, socket) do
    {:noreply, socket |> assign(:focused_hook, nil) |> assign(:focused_hook_template_b64, nil)}
  end

  @impl true
  def handle_event("toggle_hook", %{"name" => name}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_hooks, name),
        do: MapSet.delete(socket.assigns.selected_hooks, name),
        else: MapSet.put(socket.assigns.selected_hooks, name)

    {:noreply, assign(socket, :selected_hooks, selected)}
  end

  @impl true
  def handle_event("set_hook_filter", %{"value" => val}, socket) do
    {:noreply, assign(socket, :hook_filter, val)}
  end

  @impl true
  def handle_event("refresh_hooks", _, socket) do
    {:noreply, assign(socket, :all_hooks, Hooks.list_hooks())}
  end

  @impl true
  def handle_info({:cache_start_result, :ok}, socket) do
    {:noreply, assign(socket, :cache_status, :running)}
  end

  @impl true
  def handle_info({:cache_start_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:cache_status, :stopped)
     |> put_flash(:error, "Cache start failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info(:tick, %{assigns: %{running: false}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, do_tick(socket)}
  end

  @impl true
  def terminate(_reason, socket) do
    for {_id, path} <- Process.get(:sv_full_frames, %{}), do: File.rm(path)
    for key <- [:tmp_thumb, :tmp_region, :tmp_template] do
      File.rm(socket.assigns[key])
    end
    :ok
  end

  defp do_tick(socket) do
    age =
      case Native.cache_age_ms() do
        {:ok, ms} -> ms
        _ -> nil
      end

    socket = assign(socket, :cache_age_ms, age)

    counter = socket.assigns.frame_counter + 1

    case capture_frame(socket.assigns.tmp_thumb, socket.assigns.base, counter) do
      {:ok, thumb_b64, full_path, mat} ->
        frame = %{id: counter, thumb_b64: thumb_b64}
        frames = [frame | socket.assigns.frames] |> Enum.take(@max_frames)

        store_full_path(counter, full_path, frames)

        hook_results =
          run_hooks(socket.assigns.selected_hooks, mat, counter, socket.assigns.hook_results, socket.assigns.tmp_region)

        socket
        |> assign(:frames, frames)
        |> assign(:frame_counter, counter)
        |> assign(:hook_results, hook_results)
        |> assign(:status, :live)
        |> put_current_frame()

      :error ->
        assign(socket, :status, :waiting)
    end
  end

  # Write the full-res 1920×1080 JPEG to a per-frame file on disk.
  # The process dict holds only the path (~50 bytes); no bitmaps in memory.
  defp capture_frame(tmp_thumb, base, counter) do
    case Native.cache_grab_frame() do
      {:ok, binary, w, h} ->
        mat = Evision.Mat.from_binary(binary, {:u, 8}, h, w, 3)
        full_path = "#{base}_full_#{counter}.png"

        Evision.imwrite(full_path, mat)
        Evision.imwrite(tmp_thumb, Evision.resize(mat, {@thumb_w, @thumb_h}))

        case File.read(tmp_thumb) do
          {:ok, thumb_jpeg} -> {:ok, Base.encode64(thumb_jpeg), full_path, mat}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp store_full_path(frame_id, full_path, current_frames) do
    live_ids = MapSet.new(current_frames, & &1.id)
    full_map = Process.get(:sv_full_frames, %{})

    for {id, path} <- full_map, not MapSet.member?(live_ids, id) do
      File.rm(path)
    end

    pruned = Map.filter(full_map, fn {id, _} -> MapSet.member?(live_ids, id) end)
    Process.put(:sv_full_frames, Map.put(pruned, frame_id, full_path))
  end

  defp get_full_path(frame_id) do
    Process.get(:sv_full_frames, %{}) |> Map.get(frame_id)
  end

  defp put_current_frame(socket) do
    frames = socket.assigns.frames
    selected_id = socket.assigns.selected_id

    current =
      case {frames, selected_id} do
        {[], _} -> nil
        {[latest | _], nil} -> latest
        {frames, id} -> Enum.find(frames, hd(frames), &(&1.id == id))
      end

    full_b64 =
      case current && get_full_path(current.id) do
        nil -> nil
        path -> case File.read(path) do
          {:ok, jpeg} -> Base.encode64(jpeg)
          _ -> nil
        end
      end

    socket
    |> assign(:current_frame, current)
    |> assign(:current_full_b64, full_b64)
  end

  defp run_hooks(selected_hooks, _mat, _frame_id, hook_results, _tmp_region)
       when map_size(selected_hooks) == 0,
       do: hook_results

  defp run_hooks(selected_hooks, mat, frame_id, hook_results, tmp_region) do
    frame_struct = %Frame{
      binary: nil,
      mat: mat,
      window_rect: {0, 0, 1920, 1080},
      scale: 1.0,
      captured_at: System.monotonic_time(:millisecond)
    }

    Enum.reduce(selected_hooks, hook_results, fn hook_name, acc ->
      entry = match_one_hook(frame_struct, hook_name, frame_id, tmp_region)
      existing = Map.get(acc, hook_name, [])
      Map.put(acc, hook_name, [entry | existing] |> Enum.take(@max_frames))
    end)
  end

  defp match_one_hook(frame, hook_name, frame_id, tmp_region) do
    hook_atom = String.to_existing_atom(hook_name)

    case Matcher.find_with_score(frame, hook_atom) do
      {:ok, score, match} ->
        region_b64 = encode_hook_region(frame.mat, hook_atom, tmp_region)
        %{id: frame_id, score: Float.round(score, 3), matched: match != :not_found, region_b64: region_b64}

      _ ->
        %{id: frame_id, score: 0.0, matched: false, region_b64: nil}
    end
  rescue
    _ -> %{id: frame_id, score: 0.0, matched: false, region_b64: nil}
  end

  defp encode_template(hook_name, tmp) do
    hook_atom = String.to_existing_atom(hook_name)

    case HookRegistry.find(hook_atom) do
      {:ok, hook} ->
        Evision.imwrite(tmp, hook.mat)

        case File.read(tmp) do
          {:ok, jpeg} -> Base.encode64(jpeg)
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp encode_hook_region(mat, hook_atom, tmp) do
    case HookRegistry.find(hook_atom) do
      {:ok, hook} ->
        region_mat =
          case hook.region do
            nil -> Evision.resize(mat, {192, 108})
            {rx, ry, rw, rh} -> Evision.Mat.roi(mat, {rx, ry, rw, rh})
          end

        Evision.imwrite(tmp, region_mat)

        case File.read(tmp) do
          {:ok, jpeg} -> Base.encode64(jpeg)
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_ms)
  end

  # --- Template helpers ---

  def hook_result_for(hook_results, hook_name, frame_id) do
    hook_results
    |> Map.get(hook_name, [])
    |> Enum.find(&(&1.id == frame_id))
  end

  def hook_bar_class(nil), do: "bg-base-content/10"
  def hook_bar_class(%{matched: true}), do: "bg-success/60"
  def hook_bar_class(%{matched: false}), do: "bg-base-content/20"

  def score_pct(nil), do: "0%"
  def score_pct(%{score: s}), do: "#{round(s * 100)}%"

  def score_label(nil), do: ""
  def score_label(%{score: s}), do: :erlang.float_to_binary(s, [{:decimals, 3}])

  def filtered_hooks(hooks, ""), do: hooks

  def filtered_hooks(hooks, filter) do
    f = String.downcase(filter)
    Enum.filter(hooks, &String.contains?(String.downcase(&1.name), f))
  end

  def focused_result(_hook_results, nil, _current_frame), do: nil
  def focused_result(_hook_results, _hook_name, nil), do: nil

  def focused_result(hook_results, hook_name, current_frame) do
    hook_results
    |> Map.get(hook_name, [])
    |> Enum.find(&(&1.id == current_frame.id))
  end

  def focused_actual_b64(hook_results, hook_name, current_frame) do
    case focused_result(hook_results, hook_name, current_frame) do
      %{region_b64: b64} -> b64
      _ -> nil
    end
  end
end
