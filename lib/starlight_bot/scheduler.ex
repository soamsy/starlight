defmodule StarlightBot.Scheduler do
  import Ecto.Query
  alias StarlightBot.{AppSettings, DailyProgress, EnkephalinSchedule, LuxSchedule, Repo, RunHistory, RunnerForms}
  alias StarlightBot.Navigation.Navigator

  @topic "scheduler"
  @start_jitter_s 15 * 60
  @cancel_cooldown_s 3600
  @hold_hours ~w(1 2 4 8)
  @launch_modes ~w(none steam exe)
  @default_steam_app_id "1973530"
  @fields [
    :enabled,
    :window_start,
    :window_end,
    :launch_mode,
    :steam_app_id,
    :exe_path,
    :launch_timeout_s,
    :exp_waves,
    :thread_waves,
    :md_runs
  ]

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def broadcast(message), do: Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, message)

  def launch_modes, do: @launch_modes

  def default_steam_app_id, do: @default_steam_app_id

  def get_settings do
    from(s in "scheduler_settings", where: s.id == 1, select: map(s, ^@fields))
    |> Repo.one()
    |> Map.update!(:enabled, &(&1 in [true, 1]))
  end

  def save_settings(attrs) do
    with {:ok, fields} <- validate(attrs) do
      update(fields)
    end
  end

  def set_enabled(enabled?) do
    get_settings()
    |> Map.take([:window_start, :window_end, :launch_mode, :steam_app_id, :exe_path, :launch_timeout_s, :exp_waves, :thread_waves, :md_runs])
    |> Map.put(:enabled, enabled?)
    |> save_settings()
  end

  def busy?, do: EnkephalinSchedule.charging?() or navigator_busy?()

  defp navigator_busy? do
    GenServer.whereis(Navigator) != nil and
      case Navigator.status() do
        %{phase: :idle, run_kind: nil} -> false
        _ -> true
      end
  end

  def blocked(%DateTime{} = now \\ DateTime.utc_now()) do
    resume_at = stored_time("scheduler_resume_at")

    hold = stored_time("scheduler_hold_until") |> then(&(&1 && {:hold, &1}))

    canceled =
      with %DateTime{} = at <- RunHistory.last_canceled_at(),
           true <- is_nil(resume_at) or DateTime.compare(at, resume_at) == :gt do
        {:canceled, DateTime.add(at, @cancel_cooldown_s)}
      else
        _ -> nil
      end

    [hold, canceled]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn {_reason, until} -> DateTime.compare(until, now) == :gt end)
    |> Enum.max_by(fn {_reason, until} -> DateTime.to_unix(until) end, fn -> nil end)
  end

  def hold(option) when option in @hold_hours or option in ["day", "clear"] do
    now = DateTime.utc_now()

    case option do
      "clear" ->
        AppSettings.put("scheduler_hold_until", "")
        AppSettings.put("scheduler_resume_at", DateTime.to_iso8601(DateTime.truncate(now, :second)))

      "day" ->
        AppSettings.put("scheduler_hold_until", DateTime.to_iso8601(DateTime.add(LuxSchedule.day_start(now), 86_400)))

      hours ->
        AppSettings.put("scheduler_hold_until", DateTime.to_iso8601(DateTime.truncate(DateTime.add(now, String.to_integer(hours) * 3600), :second)))
    end

    broadcast({:scheduler_settings, get_settings()})
    :ok
  end

  def to_local(%DateTime{} = utc) do
    offset_s = :calendar.datetime_to_gregorian_seconds(:calendar.local_time()) - :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    utc |> DateTime.to_naive() |> NaiveDateTime.add(offset_s)
  end

  def next_start(%NaiveDateTime{} = now, settings, blocked) do
    blocked_until = blocked && to_local(elem(blocked, 1))

    Enum.find_value(-1..3, fn offset ->
      date = Date.add(NaiveDateTime.to_date(now), offset)
      {_start_at, end_at} = window(date, settings)
      planned = planned_start(date, settings)
      start_at = if blocked_until && NaiveDateTime.compare(blocked_until, planned) == :gt, do: blocked_until, else: planned

      if NaiveDateTime.compare(end_at, now) == :gt and NaiveDateTime.compare(start_at, end_at) == :lt, do: start_at
    end)
  end

  def outlook(%NaiveDateTime{} = now, settings, remaining, busy?, blocked) do
    work = DailyProgress.remaining_label(remaining)

    cond do
      not DailyProgress.pending?(remaining) -> "All of today's targets are done"
      not settings.enabled -> "Scheduler is off, #{work} left today"
      busy? -> nil
      true -> start_outlook(now, work, next_start(now, settings, blocked), blocked)
    end
  end

  defp start_outlook(_now, work, nil, _blocked), do: "Waiting to complete #{work}, no window left to start in"

  defp start_outlook(now, work, start_at, blocked) do
    text =
      cond do
        NaiveDateTime.compare(start_at, now) != :gt -> "Starting #{work} now"
        blocked_start?(start_at, blocked) -> "Will start #{work} in #{exact_duration_label(NaiveDateTime.diff(start_at, now, :second))}"
        true -> "Will start #{work} at #{clock12(start_at)} #{day_word(now, start_at)}, in #{exact_duration_label(NaiveDateTime.diff(start_at, now, :second))}"
      end

    text <> blocked_note(blocked)
  end

  defp blocked_start?(_start_at, nil), do: false
  defp blocked_start?(start_at, {_kind, until}), do: NaiveDateTime.compare(start_at, to_local(until)) == :eq

  defp blocked_note(nil), do: ""
  defp blocked_note(blocked), do: ". " <> upcase_first(blocked_reason(blocked))

  def blocked_reason({:hold, until}), do: "you paused the schedulers until #{clock12(to_local(until))}"
  def blocked_reason({:canceled, until}), do: "a run was canceled recently, waiting until #{clock12(to_local(until))}"

  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  def day_timeline(%NaiveDateTime{} = now, settings, blocked) do
    with {:ok, start_time} <- parse_time(settings.window_start),
         {:ok, end_time} <- parse_time(settings.window_end) do
      today = NaiveDateTime.to_date(now)
      start_min = minute_of_day(start_time)
      reset = DateTime.new!(Date.utc_today(), ~T[21:00:00], "Etc/UTC") |> to_local() |> minute_of_day()

      %{
        windows: window_segments(start_min, minute_of_day(end_time)),
        start_span: {start_min, min(start_min + div(start_jitter_s(settings), 60), 1440)},
        planned: today |> planned_start(settings) |> minute_of_day(),
        reset: reset,
        now: minute_of_day(now),
        blocked: blocked_span(now, blocked)
      }
    else
      _ -> nil
    end
  end

  defp blocked_span(_now, nil), do: nil

  defp blocked_span(now, {_reason, until}) do
    until = to_local(until)
    to_min = if Date.compare(NaiveDateTime.to_date(until), NaiveDateTime.to_date(now)) == :gt, do: 1440, else: minute_of_day(until)
    {minute_of_day(now), to_min}
  end

  defp minute_of_day(%{hour: hour, minute: minute}), do: hour * 60 + minute

  defp window_segments(start_min, end_min) when end_min > start_min, do: [{start_min, end_min}]
  defp window_segments(start_min, end_min), do: [{0, end_min}, {start_min, 1440}]

  def clock12(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%-I:%M %p")

  def day_word(now, at) do
    case Date.diff(NaiveDateTime.to_date(at), NaiveDateTime.to_date(now)) do
      0 -> "today"
      1 -> "tomorrow"
      _ -> Calendar.strftime(at, "%a %b %-d")
    end
  end

  defp stored_time(key) do
    with value when is_binary(value) and value != "" <- AppSettings.get(key),
         {:ok, at, _} <- DateTime.from_iso8601(value) do
      at
    else
      _ -> nil
    end
  end

  def exact_duration_label(seconds) do
    total_minutes = max(div(seconds + 59, 60), 1)

    case {div(total_minutes, 60), rem(total_minutes, 60)} do
      {0, minutes} -> "#{minutes} min"
      {hours, 0} -> "#{hours}h"
      {hours, minutes} -> "#{hours}h #{minutes} min"
    end
  end

  def duration_label(seconds) when seconds < 3600, do: "#{max(div(seconds + 59, 60), 1)} min"
  def duration_label(seconds) when seconds < 86_400, do: "#{div(seconds + 1800, 3600)}h"
  def duration_label(seconds), do: "#{div(seconds, 86_400)}d"

  defp update(fields) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update_all(from(s in "scheduler_settings", where: s.id == 1), set: Keyword.put(fields, :updated_at, now))
    settings = get_settings()
    broadcast({:scheduler_settings, settings})
    {:ok, settings}
  end

  defp validate(attrs) do
    with {:ok, _} <- parse_time(attrs.window_start),
         {:ok, _} <- parse_time(attrs.window_end),
         true <- attrs.window_start != attrs.window_end || {:error, "start and end can't be the same time"},
         true <- Enum.all?([attrs.exp_waves, attrs.thread_waves, attrs.md_runs], &(is_integer(&1) and &1 >= 0)) || {:error, "daily targets must be whole numbers, 0 or more"},
         true <- attrs.launch_mode in @launch_modes || {:error, "unknown launch mode"},
         true <- attrs.launch_mode != "steam" or Regex.match?(~r/^\d+$/, attrs.steam_app_id) || {:error, "Steam app id must be a number"},
         true <- attrs.launch_mode != "exe" or File.regular?(attrs.exe_path) || {:error, "executable path doesn't point at a file"},
         true <- is_integer(attrs.launch_timeout_s) and attrs.launch_timeout_s > 0 || {:error, "launch timeout must be a positive number of seconds"},
         [] <- missing_runner_settings(attrs) do
      {:ok,
       [
         enabled: if(attrs.enabled, do: 1, else: 0),
         window_start: attrs.window_start,
         window_end: attrs.window_end,
         launch_mode: attrs.launch_mode,
         steam_app_id: attrs.steam_app_id,
         exe_path: attrs.exe_path,
         launch_timeout_s: attrs.launch_timeout_s,
         exp_waves: attrs.exp_waves,
         thread_waves: attrs.thread_waves,
         md_runs: attrs.md_runs
       ]}
    else
      {:error, _} = error -> error
      :error -> {:error, "times must be HH:MM"}
      missing when is_list(missing) -> {:error, missing_message(missing)}
    end
  end

  def missing_runner_settings(targets) do
    lux? = targets.exp_waves > 0 or targets.thread_waves > 0

    for {needed?, label, action_fun} <- [
          {lux?, "luxcavation", fn -> lux_action(targets.exp_waves, targets.thread_waves) end},
          {targets.md_runs > 0, "mirror dungeon", fn -> md_action(targets.md_runs) end}
        ],
        needed?,
        is_nil(action_fun.()),
        do: label
  end

  def missing_message([one]), do: "the #{one} runner page isn't set up to run"
  def missing_message(missing), do: "the #{Enum.join(missing, " and ")} runner pages aren't set up to run"

  def runner_action(remaining) do
    lux = if remaining["exp"] > 0 or remaining["thread"] > 0, do: lux_action(remaining["exp"], remaining["thread"])
    md = if remaining["md"] > 0, do: md_action(remaining["md"])

    case {lux, md} do
      {nil, nil} -> nil
      {lux, nil} -> lux
      {nil, md} -> md
      {lux, md} -> {:luxcavation_then_mirror_dungeon, lux, md}
    end
  end

  defp lux_action(exp_waves, thread_waves) do
    with %{} = params <- RunnerForms.get("luxcavation"),
         {:ok, action} <- RunnerForms.luxcavation_action(Map.merge(params, %{"exp_waves" => to_string(exp_waves), "thread_waves" => to_string(thread_waves)})) do
      action
    else
      _ -> nil
    end
  end

  defp md_action(runs) do
    with %{} = params <- RunnerForms.get("mirror_dungeon"),
         {:ok, action} <- RunnerForms.mirror_dungeon_action(Map.put(params, "run_count", to_string(runs)), RunnerForms.schedulable_teams()) do
      action
    else
      _ -> nil
    end
  end

  def parse_time(value) when is_binary(value) do
    case Time.from_iso8601(value <> ":00") do
      {:ok, time} -> {:ok, time}
      _ -> :error
    end
  end

  def parse_time(_), do: :error

  def window(%Date{} = date, %{window_start: start_str, window_end: end_str}) do
    {:ok, start_time} = parse_time(start_str)
    {:ok, end_time} = parse_time(end_str)
    start_at = NaiveDateTime.new!(date, start_time)
    end_date = if Time.compare(end_time, start_time) == :gt, do: date, else: Date.add(date, 1)
    {start_at, NaiveDateTime.new!(end_date, end_time)}
  end

  def start_jitter_s(settings) do
    {start_at, end_at} = window(~D[2000-01-01], settings)
    min(@start_jitter_s, div(NaiveDateTime.diff(end_at, start_at), 2))
  end

  def latest_start_time(settings) do
    {:ok, start_time} = parse_time(settings.window_start)
    Time.add(start_time, start_jitter_s(settings))
  end

  def planned_start(%Date{} = date, settings) do
    {start_at, _end_at} = window(date, settings)
    offset_s = :erlang.phash2({Date.to_iso8601(date), settings.window_start, settings.window_end}, start_jitter_s(settings) + 1)
    NaiveDateTime.add(start_at, offset_s)
  end

  def due(%NaiveDateTime{} = now, settings) do
    today = NaiveDateTime.to_date(now)

    Enum.find_value([Date.add(today, -1), today], :not_due, fn date ->
      {_start_at, end_at} = window(date, settings)

      if NaiveDateTime.compare(now, planned_start(date, settings)) != :lt and
           NaiveDateTime.compare(now, end_at) == :lt do
        {:due, date, end_at}
      end
    end)
  end

  def next_planned(%NaiveDateTime{} = now, settings) do
    today = NaiveDateTime.to_date(now)

    [Date.add(today, -1), today, Date.add(today, 1)]
    |> Enum.find(fn date ->
      {_start_at, end_at} = window(date, settings)
      NaiveDateTime.compare(now, end_at) == :lt
    end)
    |> then(&{&1, planned_start(&1, settings), elem(window(&1, settings), 1)})
  end

  def local_now, do: NaiveDateTime.from_erl!(:calendar.local_time())
end
