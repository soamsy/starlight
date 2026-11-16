defmodule StarlightBot.AppSettings do
  import Ecto.Query

  alias StarlightBot.Automation.EnkephalinCharger
  alias StarlightBot.Repo

  def enkephalin_convert_count do
    case Repo.one(from_key("enkephalin_convert_count")) do
      nil -> 0
      value -> parse_count(value)
    end
  end

  def put_enkephalin_convert_count(count) do
    with {count, ""} <- Integer.parse(to_string(count)),
         true <- count in 0..EnkephalinCharger.max_convert_count() do
      Repo.insert_all("app_settings", [%{key: "enkephalin_convert_count", value: Integer.to_string(count)}],
        on_conflict: {:replace, [:value]},
        conflict_target: :key
      )

      {:ok, count}
    else
      _ -> :error
    end
  end

  def launcher do
    case Repo.one(from_key("launcher")) do
      "direct" -> "direct"
      "gamescope" -> "gamescope"
      "gamescope_window" -> "gamescope_window"
      _ -> "gamescope_window"
    end
  end

  def put_launcher(launcher) when launcher in ["direct", "gamescope", "gamescope_window"], do: put("launcher", launcher)

  @gamescope_resolutions ["1920x1080", "1280x720"]

  def gamescope_resolutions, do: @gamescope_resolutions

  def gamescope_resolution do
    case Repo.one(from_key("gamescope_resolution")) do
      resolution when resolution in @gamescope_resolutions -> resolution
      _ -> "1920x1080"
    end
  end

  def put_gamescope_resolution(resolution) when resolution in @gamescope_resolutions, do: put("gamescope_resolution", resolution)

  def gamescope_flags, do: Repo.one(from_key("gamescope_flags")) || ""

  def put_gamescope_flags(flags) when is_binary(flags), do: put("gamescope_flags", String.trim(flags))

  def battle_debug?, do: Repo.one(from_key("battle_debug")) == "true"

  def put_battle_debug(enabled?) when is_boolean(enabled?), do: put("battle_debug", to_string(enabled?))

  @cursor_speed_range {0.2, 2.0}
  @hesitation_range {0.5, 2.0}

  def cursor_speed, do: cached_multiplier("cursor_speed", @cursor_speed_range)

  def put_cursor_speed(value), do: put_multiplier("cursor_speed", value, @cursor_speed_range)

  def hesitation_mult, do: cached_multiplier("hesitation_mult", @hesitation_range)

  def put_hesitation_mult(value), do: put_multiplier("hesitation_mult", value, @hesitation_range)

  def get(key), do: Repo.one(from_key(key))

  def put(key, value) do
    Repo.insert_all("app_settings", [%{key: key, value: value}], on_conflict: {:replace, [:value]}, conflict_target: :key)
    :ok
  end

  defp cached_multiplier(key, range) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil ->
        value = key |> get() |> parse_multiplier(range)
        :persistent_term.put({__MODULE__, key}, value)
        value

      value ->
        value
    end
  end

  defp put_multiplier(key, value, {lo, hi} = range) do
    case parse_multiplier(to_string(value), range) do
      parsed when is_float(parsed) and parsed >= lo and parsed <= hi ->
        put(key, Float.to_string(parsed))
        :persistent_term.put({__MODULE__, key}, parsed)
        {:ok, parsed}
    end
  end

  defp parse_multiplier(value, {lo, hi}) do
    case value && Float.parse(value) do
      {parsed, _} -> parsed |> max(lo) |> min(hi) |> Float.round(2)
      _ -> 1.0
    end
  end

  defp from_key(key), do: from(s in "app_settings", where: s.key == ^key, select: s.value)

  defp parse_count(value) do
    case Integer.parse(value) do
      {count, ""} when count in 0..4 -> count
      _ -> 0
    end
  end
end
