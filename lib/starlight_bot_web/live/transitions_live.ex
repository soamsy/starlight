defmodule StarlightBotWeb.Live.TransitionsLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.{Hooks, Native, Input.Keyboard}
  alias StarlightBot.Vision.{Capture, HookRegistry, Matcher}
  alias StarlightBot.Navigation.{Catalog, Navigator}
  alias StarlightBot.Automation.Scripts

  @tick_ms 500
  @localize_interval_ms 1_500
  @countdown_secs 2
  @thumb_w 640
  @thumb_h 360
  @min_extra_hops 2
  @max_extra_hops 4

  @impl true
  def mount(_params, _session, socket) do
    cache_status =
      case Native.cache_age_ms() do
        {:ok, _} -> :running
        _ -> :stopped
      end

    if connected?(socket) do
      Navigator.subscribe()
      schedule_tick()
      schedule_localize_tick()
    end

    nav = Navigator.status()
    base = "/tmp/_starlight_tl_hook_#{System.unique_integer([:positive])}"

    {:ok,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:goal, nav.goal)
     |> assign(:phase, nav.phase)
     |> assign(:log, nav.log)
     |> assign(:frame_b64, nil)
     |> assign(:frame_age_ms, nil)
     |> assign(:transitions, transitions_for(nav.current_screen))
     |> assign(:hop_actions, hop_actions_for(nav.current_screen))
     |> assign(:actions, actions_for(nav.current_screen))
     |> assign(:pending_action, nil)
     |> assign(:countdown, nil)
     |> assign(:cache_status, cache_status)
     |> assign(:stream_running, true)
     |> assign(:all_hooks, Hooks.list_hooks())
     |> assign(:hook_filter, "")
     |> assign(:hook_test_results, %{})
     |> assign(:focused_hook, nil)
     |> assign(:tmp_hook_template, base <> ".template.jpg")
     |> assign(:tmp_hook_region, base <> ".region.jpg")
     |> assign(:scripts, Scripts.all())}
  end

  @impl true
  def handle_event("run_to", %{"screen" => screen}, socket) do
    screen_atom = String.to_existing_atom(screen)
    {:noreply, start_countdown(socket, {:run_to, screen_atom})}
  end

  @impl true
  def handle_event("run_transition", %{"name" => name}, socket) do
    name_atom = String.to_existing_atom(name)
    {:noreply, start_countdown(socket, {:run_transition, name_atom})}
  end

  @impl true
  def handle_event("run_script", %{"name" => name}, socket) do
    script_atom = String.to_existing_atom(name)
    {:noreply, start_countdown(socket, {:run_script, script_atom})}
  end

  @impl true
  def handle_event("run_action", %{"name" => name}, socket) do
    action_atom = String.to_existing_atom(name)
    {:noreply, start_countdown(socket, {:run_action, action_atom})}
  end

  @impl true
  def handle_event("cancel_pending", _, socket) do
    {:noreply, socket |> assign(:pending_action, nil) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_event("start_cache", _, socket) do
    me = self()
    Task.start(fn -> send(me, {:cache_start_result, Capture.start_cache()}) end)
    {:noreply, assign(socket, :cache_status, :starting)}
  end

  @impl true
  def handle_event("stop_cache", _, socket) do
    Capture.stop_cache()
    {:noreply, assign(socket, :cache_status, :stopped)}
  end

  @impl true
  def handle_event("toggle_stream", _, socket) do
    running = !socket.assigns.stream_running
    if running, do: schedule_tick()
    {:noreply, assign(socket, :stream_running, running)}
  end

  @impl true
  def handle_event("localize", _, socket) do
    Navigator.localize()
    {:noreply, socket}
  end

  @impl true
  def handle_event("test_type", _, socket) do
    {:noreply, start_countdown(socket, {:type, "hello"})}
  end

  @impl true
  def handle_event("cancel", _, socket) do
    Navigator.cancel()
    {:noreply, socket}
  end

  @impl true
  def handle_event("test_hook", %{"name" => name}, socket) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        result =
          match_hook(frame, name, socket.assigns.tmp_hook_template, socket.assigns.tmp_hook_region)

        {:noreply,
         socket
         |> update(:hook_test_results, &Map.put(&1, name, result))
         |> assign(:focused_hook, name)}

      {:error, :no_window} ->
        {:noreply, put_flash(socket, :error, "Game window not found.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Screenshot failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("clear_focused_hook", _, socket) do
    {:noreply, assign(socket, :focused_hook, nil)}
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
  def handle_info(:countdown_tick, %{assigns: %{pending_action: nil}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:countdown_tick, %{assigns: %{countdown: 1, pending_action: action}} = socket) do
    run_pending_action(action)
    {:noreply, socket |> assign(:pending_action, nil) |> assign(:countdown, nil)}
  end

  @impl true
  def handle_info(:countdown_tick, socket) do
    Process.send_after(self(), :countdown_tick, 1_000)
    {:noreply, assign(socket, :countdown, socket.assigns.countdown - 1)}
  end

  @impl true
  def handle_info({:nav_state, nav}, socket) do
    {:noreply,
     socket
     |> assign(:current_screen, nav.current_screen)
     |> assign(:goal, nav.goal)
     |> assign(:phase, nav.phase)
     |> assign(:log, nav.log)
     |> assign(:transitions, transitions_for(nav.current_screen))
     |> assign(:hop_actions, hop_actions_for(nav.current_screen))
     |> assign(:actions, actions_for(nav.current_screen))}
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
     |> put_flash(:error, "Stream failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info(:tick, %{assigns: %{stream_running: false}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, update_frame(socket)}
  end

  # Auto-localize while the stream is on. Only actually fires Navigator.localize()
  # when idle — Navigator.localize cancels any in-progress run_to unconditionally,
  # so firing this while a transition is executing would abort it.
  @impl true
  def handle_info(:auto_localize_tick, socket) do
    schedule_localize_tick()

    if socket.assigns.cache_status == :running and socket.assigns.stream_running and
         socket.assigns.phase == :idle do
      Navigator.localize()
    end

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    for key <- [:tmp_hook_template, :tmp_hook_region], do: File.rm(socket.assigns[key])
    :ok
  end

  # --- Hook testing ---

  defp match_hook(frame, hook_name, tmp_template, tmp_region) do
    hook_atom = String.to_existing_atom(hook_name)

    case Matcher.find_with_score(frame, hook_atom) do
      {:ok, score, match} ->
        %{
          matched: match != :not_found,
          score: Float.round(score, 3),
          template_b64: encode_hook_template(hook_atom, tmp_template),
          actual_b64: encode_searched_region(frame.mat, hook_atom, tmp_region)
        }

      _ ->
        %{matched: false, score: 0.0, template_b64: nil, actual_b64: nil}
    end
  rescue
    _ -> %{matched: false, score: 0.0, template_b64: nil, actual_b64: nil}
  end

  defp encode_hook_template(hook_atom, tmp) do
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

  # "Searched region" — scan_region when set (the wider area actually
  # scanned), else the plain region, matching Matcher's own search_region
  # resolution — so the popup shows what the matcher actually looked at.
  defp encode_searched_region(mat, hook_atom, tmp) do
    case HookRegistry.find(hook_atom) do
      {:ok, hook} ->
        region = hook.scan_region || hook.region

        region_mat =
          case region do
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

  defp update_frame(socket) do
    case Native.cache_grab_frame() do
      {:ok, binary, w, h} ->
        mat = Evision.Mat.from_binary(binary, {:u, 8}, h, w, 3)
        thumb = Evision.resize(mat, {@thumb_w, @thumb_h})
        tmp = "/tmp/_starlight_tl_thumb.jpg"
        Evision.imwrite(tmp, thumb)

        case File.read(tmp) do
          {:ok, jpeg} ->
            age =
              case Native.cache_age_ms() do
                {:ok, ms} -> ms
                _ -> nil
              end

            socket
            |> assign(:frame_b64, Base.encode64(jpeg))
            |> assign(:frame_age_ms, age)

          _ ->
            socket
        end

      _ ->
        socket
        |> assign(:frame_b64, nil)
        |> assign(:frame_age_ms, nil)
    end
  rescue
    _ -> socket
  end

  defp start_countdown(socket, action) do
    Process.send_after(self(), :countdown_tick, 1_000)

    socket
    |> assign(:pending_action, action)
    |> assign(:countdown, @countdown_secs)
  end

  defp run_pending_action({:run_to, screen}), do: Navigator.run_to(screen)
  defp run_pending_action({:type, text}), do: Keyboard.type(text)
  defp run_pending_action({:run_script, name}), do: Navigator.run_script(name)
  defp run_pending_action({:run_action, name}), do: Navigator.run_action(name)
  defp run_pending_action({:run_transition, name}), do: Navigator.run_transition(name)

  defp transitions_for(nil), do: []
  defp transitions_for(:unknown), do: []
  defp transitions_for(screen_name), do: Catalog.transitions_from(screen_name)

  defp actions_for(nil), do: []
  defp actions_for(:unknown), do: []
  defp actions_for(screen_name), do: Catalog.actions_for(screen_name)

  # Screens reachable in 2-4 hops, grouped by hop count — "N hops away".
  # reachable_from/1 is a BFS, so it records each screen once at its
  # shortest hop count; a screen also reachable in fewer hops is recorded
  # there and never shows up again at a higher count, so no extra
  # de-duplication is needed here. Returns [{hops, [screen, ...]}, ...] in
  # ascending hop order, skipping any hop level with nothing reachable.
  defp hop_actions_for(nil), do: []
  defp hop_actions_for(:unknown), do: []

  defp hop_actions_for(screen_name) do
    by_hops =
      Catalog.reachable_from(screen_name)
      |> Enum.filter(fn {_name, hops} -> hops in @min_extra_hops..@max_extra_hops end)
      |> Enum.reject(fn {name, _hops} -> unknown_fallback_screen?(name) end)
      |> Enum.group_by(fn {_name, hops} -> hops end, fn {name, _hops} -> name end)

    for hops <- @min_extra_hops..@max_extra_hops,
        screens = Map.get(by_hops, hops, []),
        screens != [] do
      {hops, screens}
    end
  end

  # Unknown-fallback screens (identity_hook: nil, e.g. :home_unknown) exist
  # purely as internal BFS bridges/localization fallbacks — nobody would
  # deliberately navigate to one, so they're excluded from the suggested
  # "N hops away" list even though they remain valid graph waypoints.
  defp unknown_fallback_screen?(name) do
    case Catalog.find_screen(name) do
      %{identity_hook: nil} -> true
      _ -> false
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp schedule_localize_tick, do: Process.send_after(self(), :auto_localize_tick, @localize_interval_ms)

  # --- Template helpers ---

  def pending_action_label({:run_to, screen}), do: "→ #{screen}"
  def pending_action_label({:type, text}), do: "type #{inspect(text)}"
  def pending_action_label({:run_action, name}), do: "⚡ #{name}"
  def pending_action_label({:run_transition, name}), do: "→ #{name}"
  def pending_action_label({:run_script, name}) do
    case Scripts.find(name) do
      %{label: label} -> "▶ #{label}"
      nil -> "▶ #{name}"
    end
  end

  def screen_label(nil), do: "Not localized"
  def screen_label(:unknown), do: "Unknown"
  def screen_label(name), do: name |> to_string() |> String.replace("_", " ")

  def screen_badge_class(nil), do: "badge badge-ghost"
  def screen_badge_class(:unknown), do: "badge badge-error"
  def screen_badge_class(_), do: "badge badge-success"

  def phase_label(:idle), do: nil
  def phase_label(:localizing), do: "Localizing…"
  def phase_label(:running), do: "Running…"

  def log_kind_class(:ok), do: "text-success"
  def log_kind_class(:error), do: "text-error"
  def log_kind_class(:info), do: "text-base-content/60"
  def log_kind_class(_), do: "text-base-content/40"

  def filtered_hooks(hooks, ""), do: hooks

  def filtered_hooks(hooks, filter) do
    f = String.downcase(filter)
    Enum.filter(hooks, &String.contains?(String.downcase(&1.name), f))
  end

  def hook_row_class(nil), do: "hover:bg-base-200"
  def hook_row_class(%{matched: true}), do: "bg-success/10 hover:bg-success/15"
  def hook_row_class(%{matched: false}), do: "bg-error/5 hover:bg-error/10"
end
