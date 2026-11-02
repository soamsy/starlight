defmodule StarlightBot.EnkephalinSchedule do
  alias StarlightBot.{AppSettings, DailyProgress, LogStore, Scheduler}
  alias StarlightBot.Navigation.Navigator

  @topic "enkephalin_schedule"
  @max_interval_minutes 7 * 24 * 60
  @enkephalin_per_hour 10
  @enkephalin_cap 160
  @enkephalin_per_module 20

  @revoked_reasons %{
    hold: "the schedulers were paused",
    cancel: "a run was cancelled",
    manual_run: "a run was started by hand",
    pause: "a run was paused",
    disabled: "the charger was turned off",
    closed: "the game was closed"
  }

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def broadcast(message), do: Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, message)

  @launch_fields [:launch_mode, :steam_app_id, :exe_path, :launch_timeout_s]

  def get_settings do
    Map.merge(Map.take(Scheduler.get_settings(), @launch_fields), %{
      enabled: AppSettings.get("enkephalin_schedule_enabled") == "true",
      window_start: AppSettings.get("enkephalin_schedule_window_start"),
      window_end: AppSettings.get("enkephalin_schedule_window_end"),
      interval_minutes: String.to_integer(AppSettings.get("enkephalin_schedule_interval_minutes")),
      close_game_after_charge: AppSettings.get("enkephalin_schedule_close_game") == "true",
      last_converted_at: parse_datetime(AppSettings.get("enkephalin_last_converted_at"))
    })
  end

  def save_settings(attrs) do
    with {:ok, _} <- Scheduler.parse_time(attrs.window_start),
         {:ok, _} <- Scheduler.parse_time(attrs.window_end),
         true <- attrs.window_start != attrs.window_end || {:error, "start and end can't be the same time"},
         true <- (is_integer(attrs.interval_minutes) and attrs.interval_minutes in 1..@max_interval_minutes) || {:error, "interval must be between 1 minute and 7 days"} do
      AppSettings.put("enkephalin_schedule_enabled", to_string(attrs.enabled))
      AppSettings.put("enkephalin_schedule_window_start", attrs.window_start)
      AppSettings.put("enkephalin_schedule_window_end", attrs.window_end)
      AppSettings.put("enkephalin_schedule_interval_minutes", Integer.to_string(attrs.interval_minutes))
      AppSettings.put("enkephalin_schedule_close_game", to_string(attrs.close_game_after_charge))
      if not attrs.enabled, do: revoke(:disabled)
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

  def close_after_charge?(charge_settings, scheduler_settings, remaining, last_run) do
    charge_settings.close_game_after_charge and match?(%{kind: :enkephalin, ok?: true}, last_run) and
      not (scheduler_settings.enabled and DailyProgress.pending?(remaining))
  end

  def ownership, do: :persistent_term.get({__MODULE__, :ownership}, nil)

  def owned?, do: ownership() == :owned

  def own_launch, do: put_ownership(:owned)

  def release, do: put_ownership(nil)

  def revoke(reason) do
    if owned?() do
      LogStore.append(:info, "enkephalin scheduler: gave up ownership of Limbus (#{reason}), it won't be closed")
      put_ownership({:revoked, reason})
    else
      :ok
    end
  end

  defp put_ownership(value) do
    :persistent_term.put({__MODULE__, :ownership}, value)
    broadcast({:enkephalin_schedule, get_settings()})
    :ok
  end

  def close_note(charge_settings, scheduler_settings, remaining) do
    case {charge_settings.close_game_after_charge, ownership()} do
      {false, _} -> "Won't close Limbus, closing is off"
      {true, nil} -> "Won't close Limbus, it was already open"
      {true, {:revoked, reason}} -> "Won't close Limbus, #{Map.fetch!(@revoked_reasons, reason)}"
      {true, :owned} ->
        if scheduler_settings.enabled and DailyProgress.pending?(remaining),
          do: "Won't close Limbus, daily goals are still pending",
          else: "Will close Limbus when the charge finishes"
    end
  end

  defp charge_run_active? do
    GenServer.whereis(Navigator) != nil and match?(%{run_kind: :enkephalin}, Navigator.status())
  end

  def charging?, do: :persistent_term.get({__MODULE__, :charging}, false)

  def set_charging(charging?), do: :persistent_term.put({__MODULE__, :charging}, charging?)

  def next_charge(%NaiveDateTime{} = now, settings, blocked) do
    Enum.find_value(-1..3, fn offset ->
      {start_at, end_at} = Scheduler.window(Date.add(NaiveDateTime.to_date(now), offset), settings)
      at = Enum.max([now, start_at, interval_gate(start_at, settings), blocked_until(blocked) || now], NaiveDateTime)
      if NaiveDateTime.compare(at, end_at) == :lt, do: at
    end)
  end

  def outlook(%NaiveDateTime{} = now, settings, blocked, busy?) do
    cond do
      not settings.enabled -> nil
      charging?() or charge_run_active?() -> "Charging enkephalin now. " <> current_close_note()
      busy? -> "Waiting for the current run to finish before charging enkephalin"
      true -> charge_outlook(now, settings, blocked, next_charge(now, settings, blocked))
    end
  end

  defp current_close_note do
    scheduler_settings = Scheduler.get_settings()
    close_note(get_settings(), scheduler_settings, DailyProgress.remaining(scheduler_settings))
  end

  defp charge_outlook(_now, _settings, _blocked, nil), do: "No charging window left to charge in"

  defp charge_outlook(now, settings, blocked, at) do
    if NaiveDateTime.compare(at, now) != :gt do
      "Charging enkephalin now"
    else
      "Will charge enkephalin#{charge_time(now, settings, at)} in #{Scheduler.exact_duration_label(NaiveDateTime.diff(at, now, :second))}" <>
        waiting_on(settings, blocked, at)
    end
  end

  defp charge_time(now, settings, at) do
    {start_at, _end_at} = current_window(at, settings)
    if NaiveDateTime.compare(start_at, at) == :eq, do: "", else: " at #{Scheduler.clock12(at)} #{Scheduler.day_word(now, at)},"
  end

  defp waiting_on(settings, blocked, at) do
    {start_at, _end_at} = current_window(at, settings)
    gate = interval_gate(start_at, settings)

    reasons =
      [
        blocked && NaiveDateTime.compare(blocked_until(blocked), at) == :eq && Scheduler.blocked_reason(blocked),
        NaiveDateTime.compare(gate, start_at) == :gt && NaiveDateTime.compare(gate, at) == :eq &&
          "the #{Scheduler.exact_duration_label(settings.interval_minutes * 60)} interval since the last charge",
        NaiveDateTime.compare(start_at, at) == :eq && "the charging window opening at #{Scheduler.clock12(at)}"
      ]
      |> Enum.filter(& &1)

    if reasons == [], do: "", else: ". Waiting on " <> Enum.join(reasons, "; ")
  end

  defp interval_gate(window_start, %{last_converted_at: last, interval_minutes: minutes}) do
    if last && NaiveDateTime.compare(last, window_start) != :lt, do: NaiveDateTime.add(last, minutes * 60), else: window_start
  end

  defp current_window(%NaiveDateTime{} = now, settings) do
    today = NaiveDateTime.to_date(now)

    [Date.add(today, -1), today]
    |> Enum.map(&Scheduler.window(&1, settings))
    |> Enum.find(fn {start_at, end_at} -> NaiveDateTime.compare(now, start_at) != :lt and NaiveDateTime.compare(now, end_at) == :lt end)
  end

  defp blocked_until(nil), do: nil
  defp blocked_until({_reason, until}), do: Scheduler.to_local(until)

  def due?(%NaiveDateTime{} = now, settings) do
    case current_window(now, settings) do
      {start_at, _end_at} -> NaiveDateTime.compare(now, interval_gate(start_at, settings)) != :lt
      nil -> false
    end
  end

  def window_end(%NaiveDateTime{} = now, settings) do
    case current_window(now, settings) do
      {_start_at, end_at} -> end_at
      nil -> nil
    end
  end

  def in_window?(%NaiveDateTime{} = now, settings), do: current_window(now, settings) != nil

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

      shown =
        first_day
        |> Date.range(shown_day)
        |> Enum.flat_map(&charges_in_window(Scheduler.window(&1, settings), step_s))
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(fn [_previous, charge] -> NaiveDateTime.to_date(charge) == shown_day end)

      spans =
        Enum.map(shown, fn [previous, charge] ->
          gap_minutes = div(NaiveDateTime.diff(charge, previous, :second), 60)
          to = minute_of_day(charge)
          Map.merge(%{from: max(to - gap_minutes, 0), to: to, gap_minutes: gap_minutes}, modules_for_minutes(gap_minutes))
        end)

      %{windows: window_segments(minute_of_day(start_time), minute_of_day(end_time)), charges: Enum.map(spans, & &1.to), spans: spans}
    else
      _ -> nil
    end
  end

  defp charges_in_window({start_at, end_at}, step_s) do
    Stream.iterate(start_at, &NaiveDateTime.add(&1, step_s)) |> Enum.take_while(&(NaiveDateTime.compare(&1, end_at) == :lt))
  end

  defp minute_of_day(%{hour: hour, minute: minute}), do: hour * 60 + minute

  defp window_segments(start_min, end_min) when end_min > start_min, do: [{start_min, end_min}]
  defp window_segments(start_min, end_min), do: [{0, end_min}, {start_min, 1440}]

  def modules_for_minutes(minutes) do
    generated = div(minutes * @enkephalin_per_hour, 60)
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
