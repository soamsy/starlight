defmodule StarlightBotWeb.Live.PageHook do
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_flash: 3]
  alias StarlightBot.{Data, GameWindow, Scheduler}
  alias StarlightBot.Vision.Capture

  @scheduler_clock_ms 30_000
  @settings_tabs ["scheduler", "data"]

  @pages %{
    StarlightBotWeb.Live.HookEditorLive => :hooks,
    StarlightBotWeb.Live.ScreenshotViewerLive => :screenshots,
    StarlightBotWeb.Live.BattleInspectorLive => :battle,
    StarlightBotWeb.Live.DungeonInspectorLive => :dungeon,
    StarlightBotWeb.Live.GiftInspectorLive => :gift_inspector,
    StarlightBotWeb.Live.ThemePackInspectorLive => :theme_packs,
    StarlightBotWeb.Live.EventInspectorLive => :events,
    StarlightBotWeb.Live.TransitionsLive => :transitions,
    StarlightBotWeb.Live.TeamEditorLive => :teams,
    StarlightBotWeb.Live.LuxcavationLive => :luxcavation,
    StarlightBotWeb.Live.RewardsLive => :rewards,
    StarlightBotWeb.Live.MirrorDungeonLive => :mirror_dungeon,
    StarlightBotWeb.Live.ShopRunnerLive => :shop_runner,
    StarlightBotWeb.Live.LogLive => :log
  }

  def on_mount(:default, _params, _session, %{parent_pid: parent} = socket) when is_pid(parent), do: {:cont, socket}

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:page, Map.get(@pages, socket.view))
      |> assign(:game_window_rect, nil)
      |> assign(:game_window_busy, nil)
      |> assign(:game_launch_label, nil)
      |> assign(:settings_open, false)
      |> assign(:settings_tab, "scheduler")
      |> assign(:app_settings, nil)
      |> assign_scheduler(Scheduler.get_settings())

    socket =
      if connected?(socket) do
        Scheduler.subscribe()
        Process.send_after(self(), :scheduler_clock, @scheduler_clock_ms)

        socket
        |> attach_hook(:settings, :handle_event, &handle_settings_event/3)
        |> attach_hook(:scheduler, :handle_info, &handle_scheduler_message/2)
      else
        socket
      end

    if connected?(socket) and GenServer.whereis(Capture) do
      Capture.subscribe()

      socket =
        socket
        |> assign(:game_window_rect, Capture.window_rect())
        |> assign(:game_launch_label, launch_label(Scheduler.get_settings()))
        |> attach_hook(:game_window_rect, :handle_info, &handle_window_rect/2)
        |> attach_hook(:game_window_actions, :handle_event, &handle_window_event/3)

      {:cont, socket}
    else
      {:cont, socket}
    end
  end

  defp handle_settings_event("settings_open", params, socket) do
    tab = if params["tab"] in @settings_tabs, do: params["tab"], else: "scheduler"
    {:halt, socket |> assign(:settings_open, true) |> assign(:settings_tab, tab) |> assign(:app_settings, Data.settings())}
  end

  defp handle_settings_event("settings_tab", %{"tab" => tab}, socket) when tab in @settings_tabs,
    do: {:halt, assign(socket, :settings_tab, tab)}

  defp handle_settings_event("scheduler_toggle", _params, socket) do
    case Scheduler.set_enabled(not socket.assigns.scheduler_settings.enabled) do
      {:ok, settings} -> {:halt, assign_scheduler(socket, settings)}
      {:error, message} -> {:halt, put_flash(socket, :error, "Scheduler not changed: #{message}")}
    end
  end

  defp handle_settings_event("settings_close", _params, socket), do: {:halt, assign(socket, :settings_open, false)}

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

  defp handle_settings_event(_event, _params, socket), do: {:cont, socket}

  defp handle_scheduler_message({:scheduler_settings, settings}, socket), do: {:halt, assign_scheduler(socket, settings)}

  defp handle_scheduler_message({:scheduler_state, %{settings: settings}}, socket), do: {:halt, assign_scheduler(socket, settings)}

  defp handle_scheduler_message(:scheduler_clock, socket) do
    Process.send_after(self(), :scheduler_clock, @scheduler_clock_ms)
    {:halt, assign_scheduler(socket, socket.assigns.scheduler_settings)}
  end

  defp handle_scheduler_message(_msg, socket), do: {:cont, socket}

  defp assign_scheduler(socket, settings) do
    socket
    |> assign(:scheduler_settings, settings)
    |> assign(:scheduler_label, Scheduler.next_run_label(Scheduler.local_now(), settings))
  end

  defp handle_window_rect({:window_rect, rect}, socket),
    do: {:halt, assign(socket, :game_window_rect, rect)}

  defp handle_window_rect({:game_window_result, kind, msg}, socket),
    do: {:halt, socket |> assign(:game_window_busy, nil) |> put_flash(kind, msg)}

  defp handle_window_rect(_msg, socket), do: {:cont, socket}

  defp handle_window_event(event, _params, %{assigns: %{game_window_busy: busy}} = socket)
       when busy != nil and event in ["game_window_resize", "game_window_launch"],
       do: {:halt, socket}

  defp handle_window_event("game_window_resize", _params, socket) do
    settings = Scheduler.get_settings()

    run_window_action(socket, "resizing to 1920x1080", fn ->
      case GameWindow.fix_aspect(settings.steam_app_id) do
        {:ok, %{before: {_, _, bw, bh}}} ->
          {:info, "Resized Limbus from #{bw}x#{bh} to 1920x1080"}

        {:error, :resize_in_progress} ->
          {:error, "A resize is already running"}

        {:error, {:resize_ignored, %{after: {_, _, aw, ah}}}} ->
          {:error, "KWin ran the resize but the window stayed #{aw}x#{ah}"}

        {:error, reason} ->
          {:error, "Resize failed: #{inspect(reason)}"}
      end
    end)
  end

  defp handle_window_event("game_window_launch", _params, socket) do
    settings = Scheduler.get_settings()

    run_window_action(socket, "launching", fn ->
      with :ok <- GameWindow.launch(settings),
           {:ok, {_, _, w, h}} <- GameWindow.await_window(settings.launch_timeout_s * 1000) do
        {:info, "Limbus window appeared (#{w}x#{h})"}
      else
        {:error, reason} -> {:error, "Launching Limbus failed: #{inspect(reason)}"}
      end
    end)
  end

  defp handle_window_event(_event, _params, socket), do: {:cont, socket}

  defp run_window_action(socket, label, fun) do
    lv = self()
    Task.Supervisor.start_child(StarlightBot.TaskSupervisor, fn ->
      {kind, msg} = fun.()
      send(lv, {:game_window_result, kind, msg})
    end)

    {:halt, assign(socket, :game_window_busy, label)}
  end

  defp launch_label(%{launch_mode: "steam", steam_app_id: id}), do: "Steam app #{id}"
  defp launch_label(%{launch_mode: "exe", exe_path: path}), do: path
  defp launch_label(_settings), do: nil
end
