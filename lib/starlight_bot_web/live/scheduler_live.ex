defmodule StarlightBotWeb.Live.SchedulerLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.{GameWindow, Scheduler, Teams}
  alias StarlightBot.Scheduler.Server
  alias StarlightBotWeb.Live.{LuxcavationLive, MirrorDungeonLive}

  @clock_tick_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Scheduler.subscribe()
      Process.send_after(self(), :clock_tick, @clock_tick_ms)
    end

    status =
      if GenServer.whereis(Server),
        do: Server.status(),
        else: %{settings: Scheduler.get_settings(), activity: nil, retry_after_ms: nil, events: []}

    {:ok,
     socket
     |> assign(:teams, Teams.list_teams() |> Enum.reject(&(&1.hook in [nil, ""])))
     |> assign(:form_md_action, nil)
     |> assign(:form_lux_action, nil)
     |> assign(:now, Scheduler.local_now())
     |> assign_status(status)
     |> assign(:form, form_values(status.settings))}
  end

  @impl true
  def handle_event("mirror_dungeon_form", params, socket) do
    {:noreply, assign(socket, :form_md_action, ok_or_nil(MirrorDungeonLive.run_action(params, socket.assigns.teams)))}
  end

  def handle_event("luxcavation_form", params, socket) do
    {:noreply, assign(socket, :form_lux_action, ok_or_nil(LuxcavationLive.run_action(params)))}
  end

  def handle_event("update_form", params, socket) do
    {:noreply, assign(socket, :form, Map.merge(socket.assigns.form, form_params(params)))}
  end

  def handle_event("save", params, socket) do
    form = Map.merge(socket.assigns.form, form_params(params))
    settings = socket.assigns.settings

    attrs = %{
      enabled: form["enabled"] == "true",
      runner: form["runner"],
      window_start: String.slice(form["window_start"], 0, 5),
      window_end: String.slice(form["window_end"], 0, 5),
      mirror_dungeon_action: socket.assigns.form_md_action || settings.mirror_dungeon_action,
      luxcavation_action: socket.assigns.form_lux_action || settings.luxcavation_action,
      launch_mode: form["launch_mode"],
      steam_app_id: String.trim(form["steam_app_id"]),
      exe_path: String.trim(form["exe_path"]),
      launch_timeout_s: parse_int(form["launch_timeout_s"])
    }

    case Scheduler.save_settings(attrs) do
      {:ok, settings} ->
        {:noreply, socket |> assign(:settings, settings) |> assign(:form, form_values(settings)) |> put_flash(:info, "Schedule saved")}

      {:error, message} ->
        {:noreply, socket |> assign(:form, form) |> put_flash(:error, "Not saved: #{message}")}
    end
  end

  def handle_event("test_launch", _, socket) do
    Server.test_launch()
    {:noreply, socket}
  end

  def handle_event("cancel_test_launch", _, socket) do
    Server.cancel_test_launch()
    {:noreply, socket}
  end

  def handle_event("test_fix_aspect", _, socket) do
    Server.test_fix_aspect()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:scheduler_state, status}, socket), do: {:noreply, assign_status(socket, status)}

  def handle_info({:scheduler_settings, settings}, socket), do: {:noreply, assign(socket, :settings, settings)}

  def handle_info(:clock_tick, socket) do
    Process.send_after(self(), :clock_tick, @clock_tick_ms)
    {:noreply, assign(socket, :now, Scheduler.local_now())}
  end

  defp assign_status(socket, status) do
    socket
    |> assign(:settings, status.settings)
    |> assign(:activity, status.activity)
    |> assign(:retry_after_ms, status.retry_after_ms)
    |> assign(:events, status.events)
  end

  defp form_values(settings) do
    %{
      "enabled" => to_string(settings.enabled),
      "runner" => settings.runner,
      "window_start" => settings.window_start,
      "window_end" => settings.window_end,
      "launch_mode" => settings.launch_mode,
      "steam_app_id" => settings.steam_app_id,
      "exe_path" => settings.exe_path || "",
      "launch_timeout_s" => to_string(settings.launch_timeout_s)
    }
  end

  defp form_params(params) do
    params
    |> Map.take(~w(runner window_start window_end launch_mode steam_app_id exe_path launch_timeout_s))
    |> Map.put("enabled", Map.get(params, "enabled", "false"))
  end

  defp ok_or_nil({:ok, action}), do: action
  defp ok_or_nil(:error), do: nil

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def action_label(nil, _teams), do: "nothing saved yet"
  def action_label({:run_mirror_dungeon, _, _, _} = action, _teams), do: MirrorDungeonLive.pending_action_label(action)

  def action_label({:run_luxcavation, team_id, exp_c, exp_r, thread_c, thread_r, _xp?, _enkephalin?, _convert}, teams) do
    team = Enum.find_value(teams, "team #{team_id}", &(&1.id == team_id && &1.name))
    "luxcavation with #{team}: exp #{exp_r} x #{exp_c}, thread #{thread_r} x #{thread_c}"
  end

  def plan_label(now, settings) do
    {date, planned, end_at} = Scheduler.next_planned(now, settings)
    day = if date == NaiveDateTime.to_date(now), do: "today", else: Calendar.strftime(date, "%a %b %-d")

    if NaiveDateTime.compare(now, planned) == :lt,
      do: "#{day}: starts at #{clock(planned)} (window ends #{clock(end_at)})",
      else: "#{day}: due now, until #{clock(end_at)}"
  end

  def clock(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%H:%M")

  def window_label(nil), do: "Limbus window not found"

  def window_label({_x, _y, w, h} = rect),
    do: "Limbus window #{w}x#{h}" <> if(GameWindow.aspect_ok?(rect), do: " (16:9)", else: " (not 16:9)")

  def event_class(:ok), do: "text-success"
  def event_class(:error), do: "text-error"
  def event_class(_), do: "text-base-content/60"
end
