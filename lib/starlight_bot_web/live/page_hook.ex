defmodule StarlightBotWeb.Live.PageHook do
  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_flash: 3]
  alias StarlightBot.{AppSettings, Data, EnkephalinSchedule, GameWindow, LauncherDeps, LogStore, Scheduler}
  alias StarlightBot.Automation.EnkephalinCharger
  alias StarlightBot.Scheduler.Overview
  alias StarlightBot.Navigation.Navigator
  alias StarlightBot.Vision.Capture
  alias StarlightBotWeb.Components.WindowGate

  @gated_pages [:runner]

  @self_subscribed_views [
    StarlightBotWeb.Live.RunnerLive,
    StarlightBotWeb.Live.TeamEditorLive,
    StarlightBotWeb.Live.TransitionsLive,
    StarlightBotWeb.Live.BattleInspectorLive,
    StarlightBotWeb.Live.ShopRunnerLive,
    StarlightBotWeb.Live.RewardsLive
  ]

  @scheduler_clock_ms 30_000
  @settings_tabs ["scheduler", "data"]
  @enkephalin_form_keys ~w(enabled window_start window_end interval_hours close_game_after_charge)

  @pages %{
    StarlightBotWeb.Live.HookEditorLive => :hooks,
    StarlightBotWeb.Live.ScreenshotViewerLive => :screenshots,
    StarlightBotWeb.Live.BattleInspectorLive => :battle,
    StarlightBotWeb.Live.BattleHistoryLive => :battle,
    StarlightBotWeb.Live.DungeonInspectorLive => :dungeon,
    StarlightBotWeb.Live.GiftInspectorLive => :gift_inspector,
    StarlightBotWeb.Live.ThemePackInspectorLive => :theme_packs,
    StarlightBotWeb.Live.EventInspectorLive => :events,
    StarlightBotWeb.Live.TransitionsLive => :transitions,
    StarlightBotWeb.Live.TeamEditorLive => :teams,
    StarlightBotWeb.Live.RewardsLive => :rewards,
    StarlightBotWeb.Live.RunnerLive => :runner,
    StarlightBotWeb.Live.ShopRunnerLive => :shop_runner,
    StarlightBotWeb.Live.LogLive => :log,
    StarlightBotWeb.Live.LinuxChecksLive => :linux_checks
  }

  def on_mount(:default, _params, _session, %{parent_pid: parent} = socket) when is_pid(parent), do: {:cont, socket}

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:page, Map.get(@pages, socket.view))
      |> assign(:game_window_rect, nil)
      |> assign(:game_window_busy, nil)
      |> assign(:run_live, false)
      |> assign(:run_paused, false)
      |> assign(:game_launch_label, nil)
      |> assign(:game_launcher_label, nil)
      |> assign(:game_update_pending, false)
      |> assign(:game_launcher_missing, [])
      |> assign(:latest_log, latest_log())
      |> assign(:settings_open, false)
      |> assign(:settings_tab, "scheduler")
      |> assign(:scheduler_view, "progress")
      |> assign(:app_settings, nil)
      |> assign(:enkephalin_convert_count, AppSettings.enkephalin_convert_count())
      |> assign_scheduler(Scheduler.get_settings())
      |> assign_enkephalin_schedule(EnkephalinSchedule.get_settings())

    socket =
      if connected?(socket) do
        Scheduler.subscribe()
        EnkephalinSchedule.subscribe()
        if socket.view != StarlightBotWeb.Live.LogLive, do: LogStore.subscribe()
        Process.send_after(self(), :scheduler_clock, @scheduler_clock_ms)

        socket
        |> attach_hook(:settings, :handle_event, &handle_settings_event/3)
        |> attach_hook(:scheduler, :handle_info, &handle_scheduler_message/2)
        |> attach_hook(:latest_log, :handle_info, &handle_log_entry/2)
      else
        socket
      end

    if connected?(socket) and GenServer.whereis(Capture) do
      Capture.subscribe()
      if socket.view not in @self_subscribed_views, do: Navigator.subscribe()

      socket =
        socket
        |> assign(:game_window_rect, Capture.window_rect())
        |> assign(:run_live, Scheduler.busy?())
        |> assign(:run_paused, run_paused?())
        |> assign_launch()
        |> attach_hook(:game_window_rect, :handle_info, &handle_window_rect/2)
        |> attach_hook(:game_window_actions, :handle_event, &handle_window_event/3)

      {:cont, socket}
    else
      {:cont, socket}
    end
  end

  defp handle_settings_event("settings_open", params, socket) do
    tab = if params["tab"] in @settings_tabs, do: params["tab"], else: "scheduler"
    socket = if params["tab"] == "enkephalin", do: assign(socket, :scheduler_view, "enkephalin"), else: socket
    {:halt, socket |> assign(:settings_open, true) |> assign(:settings_tab, tab) |> assign(:app_settings, Data.settings())}
  end

  defp handle_settings_event("scheduler_view", %{"view" => view}, socket) when view in ["runners", "enkephalin", "progress"],
    do: {:halt, assign(socket, :scheduler_view, view)}

  defp handle_settings_event("settings_tab", %{"tab" => tab}, socket) when tab in @settings_tabs,
    do: {:halt, assign(socket, :settings_tab, tab)}

  defp handle_settings_event("scheduler_toggle", _params, socket) do
    case Scheduler.set_enabled(not socket.assigns.scheduler_settings.enabled) do
      {:ok, settings} -> {:halt, assign_scheduler(socket, settings)}
      {:error, message} -> {:halt, put_flash(socket, :error, "Scheduler not changed: #{message}")}
    end
  end

  defp handle_settings_event("enkephalin_save", %{"enkephalin_convert_count" => count}, socket) do
    case AppSettings.put_enkephalin_convert_count(count) do
      {:ok, count} ->
        EnkephalinSchedule.broadcast({:enkephalin_schedule, EnkephalinSchedule.get_settings()})
        {:halt, assign(socket, :enkephalin_convert_count, count)}

      :error -> {:halt, put_flash(socket, :error, "Conversions must be a number from 0 to #{EnkephalinCharger.max_convert_count()}")}
    end
  end

  defp handle_settings_event("enkephalin_schedule_save", params, socket), do: save_enkephalin_schedule(socket, params)

  defp handle_settings_event("settings_close", _params, socket), do: {:halt, socket |> assign(:settings_open, false) |> assign_launch()}

  defp handle_settings_event("settings_save", %{"data_dir" => data_dir} = params, socket) do
    mode = if Data.authoring_allowed?(), do: Map.get(params, "mode", "user"), else: "user"

    case Data.write_config(mode: mode, data_dir: String.trim(data_dir)) do
      :ok ->
        {:halt,
         socket
         |> assign(:app_settings, Data.settings())
         |> put_flash(:info, "Saved. Restart Starlight for the new location to take effect.")}

      {:error, reason} ->
        {:halt, put_flash(socket, :error, "Couldn't save settings: #{inspect(reason)}")}
    end
  end

  defp handle_settings_event("settings_open_folder", _params, socket) do
    dir = Data.settings().data_dir
    File.mkdir_p(dir)
    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn -> System.cmd("xdg-open", [dir], stderr_to_stdout: true) end)
    {:halt, socket}
  end

  defp handle_settings_event("scheduler_hold", %{"for" => option}, socket) when option in ~w(1 2 4 8 day clear) do
    Scheduler.hold(option)
    {:halt, assign_scheduler(socket, Scheduler.get_settings())}
  end

  defp handle_settings_event("enkephalin_toggle", _params, socket) do
    case EnkephalinSchedule.set_enabled(not socket.assigns.enkephalin_schedule.enabled) do
      {:ok, settings} -> {:halt, socket |> assign(:enkephalin_form, enkephalin_form_values(settings)) |> assign_enkephalin_schedule(settings)}
      {:error, message} -> {:halt, put_flash(socket, :error, "Enkephalin scheduler not changed: #{message}")}
    end
  end

  defp handle_settings_event("scheduler_start_now", _params, socket) do
    Scheduler.Server.start_now()
    {:halt, socket}
  end

  defp handle_settings_event(_event, _params, socket), do: {:cont, socket}

  defp handle_scheduler_message({:scheduler_settings, settings}, socket), do: {:halt, assign_scheduler(socket, settings)}

  defp handle_scheduler_message({:scheduler_state, %{settings: settings}}, socket), do: {:halt, assign_scheduler(socket, settings)}

  defp handle_scheduler_message(:daily_progress, socket), do: {:halt, assign_scheduler(socket, socket.assigns.scheduler_settings)}

  defp handle_scheduler_message({:enkephalin_schedule, settings}, socket), do: {:halt, assign_enkephalin_schedule(socket, settings)}

  defp handle_scheduler_message(:scheduler_clock, socket) do
    Process.send_after(self(), :scheduler_clock, @scheduler_clock_ms)

    {:halt,
     socket
     |> assign_scheduler(socket.assigns.scheduler_settings)
     |> assign_enkephalin_schedule(socket.assigns.enkephalin_schedule)
     |> assign(:game_update_pending, update_pending?(Scheduler.get_settings()))}
  end

  defp handle_scheduler_message(_msg, socket), do: {:cont, socket}

  defp run_paused? do
    GenServer.whereis(Navigator) != nil and Navigator.status().phase == :paused
  end

  defp latest_log do
    case LogStore.recent(1) do
      [entry | _] -> entry
      [] -> nil
    end
  end

  defp handle_log_entry({:log_entry, entry}, %{view: StarlightBotWeb.Live.LogLive} = socket), do: {:cont, assign(socket, :latest_log, entry)}
  defp handle_log_entry({:log_entry, entry}, socket), do: {:halt, assign(socket, :latest_log, entry)}
  defp handle_log_entry(_msg, socket), do: {:cont, socket}

  defp assign_scheduler(socket, settings) do
    socket
    |> assign(:scheduler_settings, settings)
    |> assign_overview()
  end

  defp assign_overview(socket), do: assign(socket, :scheduler_overview, Overview.build())

  defp save_enkephalin_schedule(socket, params) do
    form = Map.merge(socket.assigns.enkephalin_form, Map.take(params, @enkephalin_form_keys))

    attrs = %{
      enabled: form["enabled"] == "true",
      window_start: String.slice(form["window_start"], 0, 5),
      window_end: String.slice(form["window_end"], 0, 5),
      interval_minutes: parse_int(form["interval_hours"], &(&1 * 60)),
      close_game_after_charge: form["close_game_after_charge"] == "true"
    }

    socket = assign(socket, :enkephalin_form, form)

    case EnkephalinSchedule.save_settings(attrs) do
      {:ok, settings} -> {:halt, socket |> assign_enkephalin_schedule(settings) |> assign(:enkephalin_schedule_error, nil)}
      {:error, message} -> {:halt, assign(socket, :enkephalin_schedule_error, message)}
    end
  end

  defp enkephalin_form_values(settings) do
    %{
      "enabled" => to_string(settings.enabled),
      "window_start" => settings.window_start,
      "window_end" => settings.window_end,
      "interval_hours" => to_string(div(settings.interval_minutes, 60)),
      "close_game_after_charge" => to_string(settings.close_game_after_charge)
    }
  end

  defp parse_int(value, fun) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> fun.(n)
      _ -> nil
    end
  end

  defp assign_enkephalin_schedule(socket, settings) do
    socket
    |> assign(:enkephalin_schedule, settings)
    |> assign_overview()
    |> assign_new(:enkephalin_schedule_error, fn -> nil end)
    |> assign_new(:enkephalin_form, fn -> enkephalin_form_values(settings) end)
  end

  defp handle_window_rect({:window_rect, rect}, socket),
    do: {:halt, assign(socket, :game_window_rect, rect)}

  defp handle_window_rect({:nav_state, state}, socket),
    do: {:cont, socket |> assign(:run_live, Scheduler.busy?()) |> assign(:run_paused, state.phase == :paused)}

  defp handle_window_rect({:game_window_result, kind, msg}, socket),
    do: {:halt, socket |> assign(:game_window_busy, nil) |> put_flash(kind, msg)}

  defp handle_window_rect(_msg, socket), do: {:cont, socket}

  defp handle_window_event(event, _params, %{assigns: %{game_window_busy: busy}} = socket)
       when busy != nil and event in ["game_window_resize", "game_window_launch", "game_window_close", "run"],
       do: {:halt, socket}

  defp handle_window_event("game_window_resize", _params, socket) do
    settings = Scheduler.get_settings()

    run_window_action(socket, "resizing to 1920x1080", fn ->
      case GameWindow.fix_aspect(settings.steam_app_id) do
        {:ok, %{before: {_, _, bw, bh}}} ->
          {:info, "Resized Limbus from #{bw}x#{bh} to 1920x1080"}

        {:error, :resize_in_progress} ->
          {:error, "A resize is already running"}

        {:error, {:resize_ignored, %{after: {_, _, aw, ah}, buses: buses}}} ->
          {:error, "#{GameWindow.resize_via_label(buses)} ran the resize but the window stayed #{aw}x#{ah}"}

        {:error, reason} ->
          {:error, "Resize failed: #{inspect(reason)}"}
      end
    end)
  end

  defp handle_window_event("game_window_launch", _params, %{assigns: %{game_update_pending: true}} = socket),
    do: {:halt, put_flash(socket, :error, "A Limbus update is pending, let Steam finish it first")}

  defp handle_window_event("game_window_launch", _params, socket) do
    run_window_action(socket, "launching", launch_action(Scheduler.get_settings(), nil))
  end

  defp handle_window_event("game_window_close", _params, %{assigns: %{run_live: true}} = socket),
    do: {:halt, put_flash(socket, :error, "A run is live, stop it before closing Limbus")}

  defp handle_window_event("game_window_close", _params, socket) do
    run_window_action(socket, "closing", fn ->
      case GameWindow.close() do
        :ok -> {:info, "Sent close signal to Limbus"}
        {:error, :not_running} -> {:error, "Limbus is not running"}
      end
    end)
  end

  defp handle_window_event("run", params, %{assigns: %{page: page}} = socket) when page in @gated_pages do
    case WindowGate.gate(socket.assigns) do
      :ready -> {:cont, socket}
      :launch -> run_window_action(socket, "launching", launch_action(Scheduler.get_settings(), params))
      :update -> {:halt, put_flash(socket, :error, "A Limbus update is pending, let Steam finish it first")}
      :resize -> {:halt, socket}
    end
  end

  defp handle_window_event(_event, _params, socket), do: {:cont, socket}

  defp launch_action(settings, run_params) do
    lv = self()

    fn ->
      with :ok <- GameWindow.launch(settings),
           {:ok, {_, _, w, h} = rect} <- GameWindow.await_settled_window(settings.launch_timeout_s * 1000) do
        cond do
          not GameWindow.aspect_ok?(rect) ->
            {:info, "Limbus opened at #{w}x#{h}, resize it to 16:9 to start the run"}

          run_params != nil ->
            send(lv, {:window_gate_run, run_params})
            {:info, "Limbus opened (#{w}x#{h}), starting the run"}

          true ->
            {:info, "Limbus window appeared (#{w}x#{h})"}
        end
      else
        {:error, :already_running} -> {:error, "Limbus is already running, close it before launching a new copy"}
        {:error, reason} -> {:error, "Launching Limbus failed: #{inspect(reason)}"}
      end
    end
  end

  defp run_window_action(socket, label, fun) do
    lv = self()
    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn ->
      {kind, msg} = fun.()
      send(lv, {:game_window_result, kind, msg})
    end)

    {:halt, assign(socket, :game_window_busy, label)}
  end

  defp assign_launch(socket) do
    settings = Scheduler.get_settings()
    launcher = AppSettings.launcher()

    socket
    |> assign(:game_launch_label, launch_label(settings))
    |> assign(:game_launcher_label, LauncherDeps.label(launcher))
    |> assign(:game_launcher_missing, LauncherDeps.missing(launcher, settings.launch_mode))
    |> assign(:game_update_pending, update_pending?(settings))
  end

  defp update_pending?(%{launch_mode: "steam", steam_app_id: id}), do: StarlightBot.SteamLaunch.update_pending?(id)
  defp update_pending?(_settings), do: false

  defp launch_label(%{launch_mode: "steam", steam_app_id: id}), do: "Steam app #{id}"
  defp launch_label(%{launch_mode: "exe", exe_path: path}), do: path
  defp launch_label(_settings), do: nil
end
