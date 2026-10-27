defmodule StarlightBot.Scheduler do
  import Ecto.Query
  alias StarlightBot.{Repo, RunnerForms}

  @topic "scheduler"
  @runners ~w(luxcavation mirror_dungeon)
  @launch_modes ~w(none steam exe)
  @fields [
    :enabled,
    :runner,
    :window_start,
    :window_end,
    :launch_mode,
    :steam_app_id,
    :exe_path,
    :launch_timeout_s,
    :last_fired_on
  ]

  def subscribe, do: Phoenix.PubSub.subscribe(StarlightBot.PubSub, @topic)

  def broadcast(message), do: Phoenix.PubSub.broadcast(StarlightBot.PubSub, @topic, message)

  def runners, do: @runners

  def launch_modes, do: @launch_modes

  def get_settings do
    from(s in "scheduler_settings", where: s.id == 1, select: map(s, ^@fields))
    |> Repo.one()
    |> Map.update!(:enabled, &(&1 in [true, 1]))
    |> Map.update!(:last_fired_on, &parse_date/1)
  end

  def save_settings(attrs) do
    with {:ok, fields} <- validate(attrs) do
      update(fields)
    end
  end

  def mark_fired(%Date{} = date), do: update(last_fired_on: Date.to_iso8601(date))

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
         true <- attrs.runner in @runners || {:error, "unknown runner"},
         true <- attrs.launch_mode in @launch_modes || {:error, "unknown launch mode"},
         true <- attrs.launch_mode != "steam" or Regex.match?(~r/^\d+$/, attrs.steam_app_id) || {:error, "Steam app id must be a number"},
         true <- attrs.launch_mode != "exe" or File.regular?(attrs.exe_path) || {:error, "executable path doesn't point at a file"},
         true <- is_integer(attrs.launch_timeout_s) and attrs.launch_timeout_s > 0 || {:error, "launch timeout must be a positive number of seconds"},
         [] <- missing_runner_settings(attrs.runner) do
      {:ok,
       [
         enabled: if(attrs.enabled, do: 1, else: 0),
         runner: attrs.runner,
         window_start: attrs.window_start,
         window_end: attrs.window_end,
         launch_mode: attrs.launch_mode,
         steam_app_id: attrs.steam_app_id,
         exe_path: attrs.exe_path,
         launch_timeout_s: attrs.launch_timeout_s
       ]}
    else
      {:error, _} = error -> error
      :error -> {:error, "times must be HH:MM"}
      missing when is_list(missing) -> {:error, missing_message(missing)}
    end
  end

  def missing_runner_settings(runner) do
    for {part, label, action_fun} <- [
          {"luxcavation", "luxcavation", &RunnerForms.luxcavation_action/0},
          {"mirror_dungeon", "mirror dungeon", &RunnerForms.mirror_dungeon_action/0}
        ],
        part in runner_parts(runner),
        is_nil(action_fun.()),
        do: label
  end

  def missing_message([one]), do: "the #{one} runner page isn't set up to run"
  def missing_message(missing), do: "the #{Enum.join(missing, " and ")} runner pages aren't set up to run"

  defp runner_parts("luxcavation"), do: if(RunnerForms.luxcavation_then_mirror_dungeon?(), do: ["luxcavation", "mirror_dungeon"], else: ["luxcavation"])
  defp runner_parts(runner), do: [runner]

  def runner_action(%{runner: "mirror_dungeon"}), do: RunnerForms.mirror_dungeon_action()

  def runner_action(%{runner: "luxcavation"}) do
    with lux when lux != nil <- RunnerForms.luxcavation_action() do
      if RunnerForms.luxcavation_then_mirror_dungeon?() do
        with md when md != nil <- RunnerForms.mirror_dungeon_action(), do: {:luxcavation_then_mirror_dungeon, lux, md}
      else
        lux
      end
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

  def planned_start(%Date{} = date, settings) do
    {start_at, end_at} = window(date, settings)
    half_s = div(NaiveDateTime.diff(end_at, start_at), 2)
    offset_s = :erlang.phash2({Date.to_iso8601(date), settings.window_start, settings.window_end}, half_s + 1)
    NaiveDateTime.add(start_at, offset_s)
  end

  def due(%NaiveDateTime{} = now, settings) do
    today = NaiveDateTime.to_date(now)

    Enum.find_value([Date.add(today, -1), today], :not_due, fn date ->
      {_start_at, end_at} = window(date, settings)

      if settings.last_fired_on != date and
           NaiveDateTime.compare(now, planned_start(date, settings)) != :lt and
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
      settings.last_fired_on != date and NaiveDateTime.compare(now, end_at) == :lt
    end)
    |> then(&{&1, planned_start(&1, settings), elem(window(&1, settings), 1)})
  end

  def local_now, do: NaiveDateTime.from_erl!(:calendar.local_time())

  defp parse_date(nil), do: nil
  defp parse_date(value), do: Date.from_iso8601!(value)
end
