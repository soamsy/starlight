defmodule StarlightBotWeb.Live.ScreenshotViewerLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.{Hooks, Vision.Capture, Vision.Frame, Vision.HookRegistry, Vision.ImageB64, Vision.Matcher}

  @max_frames 40
  @tick_ms 500
  @handoff_path "/tmp/_starlight_hook_handoff.jpg"
  @thumb_w 192
  @thumb_h 108
  @selected_hooks_key {__MODULE__, :selected_hooks}

  @impl true
  def mount(_params, _session, socket) do
    session_id = System.unique_integer([:positive])

    {:ok,
     socket
     |> assign(:frames, [])
     |> assign(:selected_id, nil)
     |> assign(:recording, false)
     |> assign(:frame_counter, 0)
     |> assign(:status, :waiting)
     |> assign(:current_frame, nil)
     |> assign(:session_id, session_id)
     |> assign(:current_full_src, nil)
     |> assign(:focused_hook, nil)
     |> assign(:focused_hook_template_b64, nil)
     |> assign(:all_hooks, Hooks.list_hooks())
     |> assign(:selected_hooks, :persistent_term.get(@selected_hooks_key, MapSet.new()))
     |> assign(:hook_results, %{})
     |> assign(:hook_filter, "")
     |> assign(:max_frames, @max_frames)}
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
  def handle_event("toggle_recording", _, socket) do
    recording = !socket.assigns.recording
    if recording, do: schedule_tick()
    {:noreply, assign(socket, :recording, recording)}
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
    template_b64 = encode_template(hook_name)

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

    :persistent_term.put(@selected_hooks_key, selected)
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
  def handle_info(:tick, %{assigns: %{recording: false}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, do_tick(socket)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    for {_id, path} <- Process.get(:sv_full_frames, %{}), do: File.rm(path)
    :ok
  end

  defp do_tick(socket) do
    counter = socket.assigns.frame_counter + 1

    case capture_frame(socket.assigns.session_id, counter) do
      {:ok, thumb_b64, full_path, mat} ->
        frame = %{id: counter, thumb_b64: thumb_b64}
        frames = [frame | socket.assigns.frames] |> Enum.take(@max_frames)

        store_full_path(counter, full_path, frames)

        hook_results =
          run_hooks(socket.assigns.selected_hooks, mat, counter, socket.assigns.hook_results)

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
  def full_path(session_id, frame_id), do: "/tmp/_starlight_sv_#{session_id}_full_#{frame_id}.png"

  defp capture_frame(session_id, counter) do
    case Capture.grab_frame() do
      {:ok, %Frame{mat: mat}} ->
        full_path = full_path(session_id, counter)

        Evision.imwrite(full_path, mat)

        case ImageB64.thumb(mat, @thumb_w, @thumb_h) do
          nil -> :error
          thumb_b64 -> {:ok, thumb_b64, full_path, mat}
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

    socket
    |> assign(:current_frame, current)
    |> assign(:current_full_src, current && get_full_path(current.id) && "/screenshots/frame/#{socket.assigns.session_id}/#{current.id}.png")
  end

  defp run_hooks(selected_hooks, _mat, _frame_id, hook_results)
       when map_size(selected_hooks) == 0,
       do: hook_results

  defp run_hooks(selected_hooks, mat, frame_id, hook_results) do
    frame_struct = %Frame{
      binary: nil,
      mat: mat,
      window_rect: {0, 0, 1920, 1080},
      scale: 1.0,
      captured_at: System.monotonic_time(:millisecond)
    }

    Enum.reduce(selected_hooks, hook_results, fn hook_name, acc ->
      entry = match_one_hook(frame_struct, hook_name, frame_id)
      existing = Map.get(acc, hook_name, [])
      Map.put(acc, hook_name, [entry | existing] |> Enum.take(@max_frames))
    end)
  end

  defp match_one_hook(frame, hook_name, frame_id) do
    hook_atom = String.to_existing_atom(hook_name)

    case Matcher.find_with_score(frame, hook_atom) do
      {:ok, score, match} ->
        region_b64 = encode_hook_region(frame.mat, hook_atom)
        %{id: frame_id, score: Float.round(score, 3), matched: match != :not_found, region_b64: region_b64}

      _ ->
        %{id: frame_id, score: 0.0, matched: false, region_b64: nil}
    end
  rescue
    _ -> %{id: frame_id, score: 0.0, matched: false, region_b64: nil}
  end

  defp encode_template(hook_name) do
    hook_atom = String.to_existing_atom(hook_name)

    case HookRegistry.find(hook_atom) do
      {:ok, hook} -> ImageB64.jpeg(hook.mat)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp encode_hook_region(mat, hook_atom) do
    case HookRegistry.find(hook_atom) do
      {:ok, hook} ->
        region_mat =
          case hook.region do
            nil -> Evision.resize(mat, {192, 108})
            {rx, ry, rw, rh} -> Frame.crop(mat, {rx, ry, rw, rh})
          end

        ImageB64.jpeg(region_mat)

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
