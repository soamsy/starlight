defmodule StarlightBotWeb.Live.SchedulerLive do
  use StarlightBotWeb, :live_view
  alias StarlightBot.{DailyProgress, EnkephalinSchedule, Scheduler}
  alias StarlightBot.Scheduler.Server
  alias StarlightBotWeb.Live.LuxcavationLive

  @clock_tick_ms 30_000
  @md_modules_per_run 5
  @modules_per_conversion 7
  @daily_charge_modules 12
  @launch_keys ~w(launch_mode steam_app_id exe_path launch_timeout_s)
  @runner_keys ~w(window_start window_end exp_waves thread_waves md_runs)

  embed_templates "scheduler_live/*"

  @impl true
  def render(%{part: "progress"} = assigns), do: progress(assigns)
  def render(%{part: "launch"} = assigns), do: launch(assigns)
  def render(assigns), do: runners_form(assigns)

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Scheduler.subscribe()
      EnkephalinSchedule.subscribe()
      Process.send_after(self(), :clock_tick, @clock_tick_ms)
    end

    status =
      if GenServer.whereis(Server),
        do: Server.status(),
        else: %{settings: Scheduler.get_settings(), activity: nil, retry_after_ms: nil, events: []}

    {:ok,
     socket
     |> assign(:part, session["part"])
     |> assign_status(status)
     |> assign_outlook()
     |> assign(:form, form_values(status.settings))
     |> assign(:save_error, nil)}
  end

  @impl true
  def handle_event("update_form", params, socket),
    do: save_form(socket, Map.merge(socket.assigns.form, form_params(params)))

  def handle_event("scheduler_hold", %{"for" => option}, socket) when option in ~w(1 2 4 8 day clear) do
    Scheduler.hold(option)
    {:noreply, assign_outlook(socket)}
  end

  def handle_event("scheduler_start_now", _params, socket) do
    Server.start_now()
    {:noreply, socket}
  end

  def handle_event("reset_steam_app_id", _params, socket),
    do: save_form(socket, Map.put(socket.assigns.form, "steam_app_id", Scheduler.default_steam_app_id()))

  @impl true
  def handle_info({:scheduler_state, status}, socket), do: {:noreply, socket |> assign_status(status) |> assign_outlook()}

  def handle_info({:scheduler_settings, settings}, socket), do: {:noreply, socket |> assign(:settings, settings) |> assign_outlook()}

  def handle_info(:daily_progress, socket), do: {:noreply, assign_outlook(socket)}

  def handle_info({:enkephalin_schedule, _settings}, socket), do: {:noreply, assign_outlook(socket)}

  def handle_info(:clock_tick, socket) do
    Process.send_after(self(), :clock_tick, @clock_tick_ms)
    {:noreply, socket |> assign_server_status() |> assign_outlook()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp save_form(socket, form) do
    form = Map.merge(form_values(socket.assigns.settings), Map.take(form, form_keys(socket.assigns.part)))

    attrs = %{
      enabled: socket.assigns.settings.enabled,
      window_start: String.slice(form["window_start"], 0, 5),
      window_end: String.slice(form["window_end"], 0, 5),
      launch_mode: form["launch_mode"],
      steam_app_id: String.trim(form["steam_app_id"]),
      exe_path: String.trim(form["exe_path"]),
      launch_timeout_s: parse_int(form["launch_timeout_s"]),
      exp_waves: parse_int(form["exp_waves"]),
      thread_waves: parse_int(form["thread_waves"]),
      md_runs: parse_int(form["md_runs"])
    }

    socket = assign(socket, :form, form)

    case Scheduler.save_settings(attrs) do
      {:ok, settings} -> {:noreply, socket |> assign(:settings, settings) |> assign(:save_error, nil)}
      {:error, message} -> {:noreply, assign(socket, :save_error, message)}
    end
  end

  defp form_keys("launch"), do: @launch_keys
  defp form_keys(_part), do: @runner_keys

  defp assign_outlook(socket) do
    settings = socket.assigns.settings
    blocked = Scheduler.blocked()

    remaining = DailyProgress.remaining(settings)

    socket
    |> assign(:pending, DailyProgress.pending?(remaining))
    |> assign(:progress, DailyProgress.completed())
    |> assign(:now, Scheduler.local_now())
    |> assign(:blocked, blocked)
    |> assign(:charger, EnkephalinSchedule.get_settings())
    |> assign(:convert_count, StarlightBot.AppSettings.enkephalin_convert_count())
    |> assign(:outlook, Scheduler.outlook(Scheduler.local_now(), settings, remaining, Scheduler.busy?(), blocked, socket.assigns[:retry_after_ms]))
  end

  defp assign_server_status(socket) do
    if GenServer.whereis(Server), do: assign_status(socket, Server.status()), else: socket
  end

  defp assign_status(socket, status) do
    socket
    |> assign(:settings, status.settings)
    |> assign(:activity, status.activity)
    |> assign(:retry_after_ms, status.retry_after_ms)
  end

  defp form_values(settings) do
    %{
      "window_start" => settings.window_start,
      "window_end" => settings.window_end,
      "launch_mode" => settings.launch_mode,
      "steam_app_id" => settings.steam_app_id,
      "exe_path" => settings.exe_path || "",
      "launch_timeout_s" => to_string(settings.launch_timeout_s),
      "exp_waves" => to_string(settings.exp_waves),
      "thread_waves" => to_string(settings.thread_waves),
      "md_runs" => to_string(settings.md_runs)
    }
  end

  defp form_params(params) do
    Map.take(params, @launch_keys ++ @runner_keys)
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def progress_modules(rows, :done), do: rows |> Enum.map(fn {_label, done, target, _unit, cost} -> min(done, target) * cost end) |> Enum.sum()
  def progress_modules(rows, :target), do: rows |> Enum.map(fn {_label, _done, target, _unit, cost} -> target * cost end) |> Enum.sum()

  def charge_modules, do: @daily_charge_modules

  def lunacy_modules(convert_count), do: convert_count * @modules_per_conversion

  def modules_net(rows, charger, convert_count) do
    charge = if charger.enabled, do: @daily_charge_modules, else: 0
    charge + lunacy_modules(convert_count) - progress_modules(rows, :target)
  end

  def signed(n) when n > 0, do: "+#{n}"
  def signed(n), do: "#{n}"

  def modules_total(terms), do: terms |> Enum.map(fn {_label, runs, cost} -> runs * cost end) |> Enum.sum()

  def term_badge_class("EXP"), do: "badge-info"
  def term_badge_class("THREAD"), do: "badge-secondary"
  def term_badge_class("MD"), do: "badge-primary"

  def progress_rows(settings, progress) do
    [
      {"EXP", progress["exp"], settings.exp_waves, "waves", LuxcavationLive.exp_enkephalin_cost()},
      {"THREAD", progress["thread"], settings.thread_waves, "waves", LuxcavationLive.thread_enkephalin_cost()},
      {"MD", progress["md"], settings.md_runs, "runs", @md_modules_per_run}
    ]
  end

  def timeline(form, now, blocked) do
    Scheduler.day_timeline(now, %{window_start: String.slice(form["window_start"], 0, 5), window_end: String.slice(form["window_end"], 0, 5)}, blocked)
  end

  def timeline_clock(minute), do: StarlightBotWeb.Layouts.timeline_clock(minute)

  def latest_start_label(form) do
    settings = %{window_start: String.slice(form["window_start"], 0, 5), window_end: String.slice(form["window_end"], 0, 5)}

    with {:ok, _} <- Scheduler.parse_time(settings.window_start),
         {:ok, _} <- Scheduler.parse_time(settings.window_end) do
      Calendar.strftime(Scheduler.latest_start_time(settings), "%-I:%M %p")
    else
      _ -> nil
    end
  end
end
