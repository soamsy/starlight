defmodule StarlightBot.Repo.Migrations.BattlePlanSlotsToWhere do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM battle_plans WHERE data LIKE '%"slots":{%'|)

    for [id, json] <- rows do
      data = json |> Jason.decode!() |> convert()
      repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(data), id])
    end
  end

  def down, do: :ok

  defp convert(%{"who" => "slots", "slots" => %{"row" => row, "is" => is?, "match" => match}} = holder) do
    condition = %{"kind" => kind(row, is?), "values" => [match]}
    holder |> Map.delete("slots") |> Map.merge(%{"who" => "everyone", "where" => %{"join" => "and", "conditions" => [condition]}}) |> convert_children()
  end

  defp convert(%{} = map), do: convert_children(map)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other

  defp convert_children(map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)

  defp kind("top", true), do: "top_is"
  defp kind("top", false), do: "top_is_not"
  defp kind("available", true), do: "has"
  defp kind("available", false), do: "has_no"
  defp kind(_bottom, true), do: "bottom_is"
  defp kind(_bottom, false), do: "bottom_is_not"
end
