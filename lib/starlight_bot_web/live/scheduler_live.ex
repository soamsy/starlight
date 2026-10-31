defmodule StarlightBotWeb.Live.SchedulerLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.{RunnerForms, Scheduler}
  alias StarlightBot.Scheduler.Server
  alias StarlightBotWeb.Live.LuxcavationLive

  @clock_tick_ms 30_000
  @md_modules_per_run 5

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Scheduler.subscribe()
      RunnerForms.subscribe()
      Process.send_after(self(), :clock_tick, @clock_tick_ms)
    end

    status =
      if GenServer.whereis(Server),
        do: Server.status(),
        else: %{settings: Scheduler.get_settings(), activity: nil, retry_after_ms: nil, events: []}

    {:ok,
     socket
     |> assign_runner_actions()
     |> assign(:now, Scheduler.local_now())
     |> assign_status(status)
     |> assign(:form, form_values(status.settings))
     |> assign(:save_error, nil)}
  end

  @impl true
  def handle_event("update_form", params, socket),
    do: save_form(socket, Map.merge(socket.assigns.form, form_params(params)))

  def handle_event("reset_steam_app_id", _params, socket),
    do: save_form(socket, Map.put(socket.assigns.form, "steam_app_id", Scheduler.default_steam_app_id()))

  @impl true
  def handle_info({:scheduler_state, status}, socket), do: {:noreply, assign_status(socket, status)}

  def handle_info({:scheduler_settings, settings}, socket), do: {:noreply, assign(socket, :settings, settings)}

  def handle_info({:runner_form, _runner}, socket), do: {:noreply, assign_runner_actions(socket)}

  def handle_info(:clock_tick, socket) do
    Process.send_after(self(), :clock_tick, @clock_tick_ms)
    {:noreply, assign(socket, :now, Scheduler.local_now())}
  end

  defp save_form(socket, form) do
    attrs = %{
      enabled: form["enabled"] == "true",
      runner: form["runner"],
      window_start: String.slice(form["window_start"], 0, 5),
      window_end: String.slice(form["window_end"], 0, 5),
      launch_mode: form["launch_mode"],
      steam_app_id: String.trim(form["steam_app_id"]),
      exe_path: String.trim(form["exe_path"]),
      launch_timeout_s: parse_int(form["launch_timeout_s"])
    }

    socket = assign(socket, :form, form)

    case Scheduler.save_settings(attrs) do
      {:ok, settings} -> {:noreply, socket |> assign(:settings, settings) |> assign(:save_error, nil)}
      {:error, message} -> {:noreply, assign(socket, :save_error, message)}
    end
  end

  defp assign_status(socket, status) do
    socket
    |> assign(:settings, status.settings)
    |> assign(:activity, status.activity)
    |> assign(:retry_after_ms, status.retry_after_ms)
  end

  defp assign_runner_actions(socket) do
    socket
    |> assign(:md_action, RunnerForms.mirror_dungeon_action())
    |> assign(:lux_action, RunnerForms.luxcavation_action())
    |> assign(:lux_then_md?, RunnerForms.luxcavation_then_mirror_dungeon?())
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

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def module_terms(runner, lux_action, md_action, lux_then_md?) do
    actions =
      case runner do
        "luxcavation" -> [lux_action | if(lux_then_md?, do: [md_action], else: [])]
        "mirror_dungeon" -> [md_action]
      end

    if Enum.any?(actions, &is_nil/1), do: nil, else: actions |> Enum.flat_map(&action_terms/1) |> Enum.reject(fn {_label, runs, _cost} -> runs == 0 end)
  end

  def modules_total(terms), do: terms |> Enum.map(fn {_label, runs, cost} -> runs * cost end) |> Enum.sum()

  def term_badge_class("EXP"), do: "badge-info"
  def term_badge_class("THREAD"), do: "badge-secondary"
  def term_badge_class("MD"), do: "badge-primary"

  defp action_terms({:run_luxcavation, _teams, exp_consecutive, exp_repeats, thread_consecutive, thread_repeats, _xp?, _enkephalin?, _convert}) do
    [
      {"EXP", exp_consecutive * exp_repeats, LuxcavationLive.exp_enkephalin_cost()},
      {"THREAD", thread_consecutive * thread_repeats, LuxcavationLive.thread_enkephalin_cost()}
    ]
  end

  defp action_terms({:run_mirror_dungeon, _picks, run_count, _config}), do: [{"MD", run_count, @md_modules_per_run}]

  def plan_label(now, settings) do
    {date, planned, end_at} = Scheduler.next_planned(now, settings)
    day = if date == NaiveDateTime.to_date(now), do: "today", else: Calendar.strftime(date, "%a %b %-d")

    if NaiveDateTime.compare(now, planned) == :lt,
      do: "#{day}: starts at #{clock(planned)}, in #{Scheduler.exact_duration_label(NaiveDateTime.diff(planned, now, :second))} (window ends #{clock(end_at)})",
      else: "#{day}: due now, until #{clock(end_at)}"
  end

  def clock(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%H:%M")
end
