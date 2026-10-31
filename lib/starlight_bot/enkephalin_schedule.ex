defmodule StarlightBot.EnkephalinSchedule do
  alias StarlightBot.{AppSettings, Scheduler}

  @topic "enkephalin_schedule"
  @max_interval_minutes 7 * 24 * 60
  @enkephalin_per_hour 10
  @enkephalin_cap 160
  @enkephalin_per_module 20

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def broadcast(message), do: Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, message)

  def get_settings do
    %{
      enabled: AppSettings.get("enkephalin_schedule_enabled") == "true",
      window_start: AppSettings.get("enkephalin_schedule_window_start"),
      window_end: AppSettings.get("enkephalin_schedule_window_end"),
      interval_minutes: String.to_integer(AppSettings.get("enkephalin_schedule_interval_minutes")),
      launch_mode: AppSettings.get("enkephalin_schedule_launch_mode"),
      steam_app_id: AppSettings.get("enkephalin_schedule_steam_app_id"),
      exe_path: AppSettings.get("enkephalin_schedule_exe_path"),
      launch_timeout_s: String.to_integer(AppSettings.get("enkephalin_schedule_launch_timeout_s")),
      last_converted_at: parse_datetime(AppSettings.get("enkephalin_last_converted_at"))
    }
  end

  def save_settings(attrs) do
    with {:ok, _} <- Scheduler.parse_time(attrs.window_start),
         {:ok, _} <- Scheduler.parse_time(attrs.window_end),
         true <- attrs.window_start != attrs.window_end || {:error, "start and end can't be the same time"},
         true <- (is_integer(attrs.interval_minutes) and attrs.interval_minutes in 1..@max_interval_minutes) || {:error, "interval must be between 1 minute and 7 days"},
         true <- attrs.launch_mode in Scheduler.launch_modes() || {:error, "unknown launch mode"},
         true <- attrs.launch_mode != "steam" or Regex.match?(~r/^\d+$/, attrs.steam_app_id) || {:error, "Steam app id must be a number"},
         true <- attrs.launch_mode != "exe" or File.regular?(attrs.exe_path) || {:error, "executable path doesn't point at a file"},
         true <- (is_integer(attrs.launch_timeout_s) and attrs.launch_timeout_s > 0) || {:error, "launch timeout must be a positive number of seconds"} do
      AppSettings.put("enkephalin_schedule_enabled", to_string(attrs.enabled))
      AppSettings.put("enkephalin_schedule_window_start", attrs.window_start)
      AppSettings.put("enkephalin_schedule_window_end", attrs.window_end)
      AppSettings.put("enkephalin_schedule_interval_minutes", Integer.to_string(attrs.interval_minutes))
      AppSettings.put("enkephalin_schedule_launch_mode", attrs.launch_mode)
      AppSettings.put("enkephalin_schedule_steam_app_id", attrs.steam_app_id)
      AppSettings.put("enkephalin_schedule_exe_path", attrs.exe_path)
      AppSettings.put("enkephalin_schedule_launch_timeout_s", Integer.to_string(attrs.launch_timeout_s))
      settings = get_settings()
      broadcast({:enkephalin_schedule, settings})
      {:ok, settings}
    else
      :error -> {:error, "times must be HH:MM"}
      {:error, _} = error -> error
    end
  end

  def set_enabled(enabled?), do: get_settings() |> Map.put(:enabled, enabled?) |> save_settings()

  def mark_converted(%NaiveDateTime{} = at \\ Scheduler.local_now()) do
    AppSettings.put("enkephalin_last_converted_at", NaiveDateTime.to_iso8601(NaiveDateTime.truncate(at, :second)))
    broadcast({:enkephalin_schedule, get_settings()})
    :ok
  end

  def due?(%NaiveDateTime{} = now, settings), do: in_window?(now, settings) and interval_elapsed?(now, settings)

  def window_end(%NaiveDateTime{} = now, settings) do
    today = NaiveDateTime.to_date(now)

    [Date.add(today, -1), today]
    |> Enum.map(&Scheduler.window(&1, settings))
    |> Enum.find_value(fn {start_at, end_at} ->
      if NaiveDateTime.compare(now, start_at) != :lt and NaiveDateTime.compare(now, end_at) == :lt, do: end_at
    end)
  end

  def in_window?(%NaiveDateTime{} = now, settings) do
    today = NaiveDateTime.to_date(now)

    Enum.any?([Date.add(today, -1), today], fn date ->
      {start_at, end_at} = Scheduler.window(date, settings)
      NaiveDateTime.compare(now, start_at) != :lt and NaiveDateTime.compare(now, end_at) == :lt
    end)
  end

  def interval_elapsed?(_now, %{last_converted_at: nil}), do: true

  def interval_elapsed?(now, %{last_converted_at: last, interval_minutes: minutes}),
    do: NaiveDateTime.diff(now, last, :second) >= minutes * 60

  @timeline_days 30

  def day_timeline(window_start, window_end, interval_hours) do
    settings = %{window_start: window_start, window_end: window_end}

    with {:ok, start_time} <- Scheduler.parse_time(window_start),
         {:ok, end_time} <- Scheduler.parse_time(window_end),
         true <- window_start != window_end,
         true <- is_integer(interval_hours) and interval_hours > 0 do
      first_day = ~D[2026-01-01]
      shown_day = Date.add(first_day, @timeline_days)
      step_s = interval_hours * 3600

      charges =
        first_day
        |> Date.range(shown_day)
        |> Enum.flat_map_reduce(nil, fn date, last -> charges_in_window(Scheduler.window(date, settings), last, step_s) end)
        |> elem(0)
        |> Enum.filter(&(NaiveDateTime.to_date(&1) == shown_day))
        |> Enum.map(&minute_of_day/1)

      %{windows: window_segments(minute_of_day(start_time), minute_of_day(end_time)), charges: charges}
    else
      _ -> nil
    end
  end

  defp charges_in_window({start_at, end_at}, last, step_s) do
    first = if last, do: Enum.max([start_at, NaiveDateTime.add(last, step_s)], NaiveDateTime), else: start_at
    times = Stream.iterate(first, &NaiveDateTime.add(&1, step_s)) |> Enum.take_while(&(NaiveDateTime.compare(&1, end_at) == :lt))
    {times, List.last(times) || last}
  end

  defp minute_of_day(%{hour: hour, minute: minute}), do: hour * 60 + minute

  defp window_segments(start_min, end_min) when end_min > start_min, do: [{start_min, end_min}]
  defp window_segments(start_min, end_min), do: [{0, end_min}, {start_min, 1440}]

  def modules_per_charge(interval_hours) do
    generated = interval_hours * @enkephalin_per_hour
    banked = min(generated, @enkephalin_cap)
    %{generated: generated, banked: banked, capped?: generated > @enkephalin_cap, modules: div(banked, @enkephalin_per_module), leftover: rem(banked, @enkephalin_per_module)}
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, at} -> at
      _ -> nil
    end
  end
end
