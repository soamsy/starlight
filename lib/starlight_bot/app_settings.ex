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

  defp from_key(key), do: from(s in "app_settings", where: s.key == ^key, select: s.value)

  defp parse_count(value) do
    case Integer.parse(value) do
      {count, ""} when count in 0..4 -> count
      _ -> 0
    end
  end
end
