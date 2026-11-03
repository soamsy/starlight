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
      _ -> "kwin"
    end
  end

  def put_launcher(launcher) when launcher in ["direct", "kwin", "gamescope", "gamescope_window"], do: put("launcher", launcher)

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

  def get(key), do: Repo.one(from_key(key))

  def put(key, value) do
    Repo.insert_all("app_settings", [%{key: key, value: value}], on_conflict: {:replace, [:value]}, conflict_target: :key)
    :ok
  end

  defp from_key(key), do: from(s in "app_settings", where: s.key == ^key, select: s.value)

  defp parse_count(value) do
    case Integer.parse(value) do
      {count, ""} when count in 0..4 -> count
      _ -> 0
    end
  end
end
