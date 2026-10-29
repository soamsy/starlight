defmodule StarlightBot.Repo.Migrations.BattlePlanChosenToWhere do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM battle_plans WHERE data LIKE '%"chosen"%'|)

    for [id, json] <- rows do
      data = json |> Jason.decode!() |> convert()
      repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(data), id])
    end
  end

  def down, do: :ok

  defp convert(%{"who" => "chosen", "chosen" => filter} = holder) do
    holder |> Map.drop(~w(chosen)) |> Map.merge(%{"who" => "everyone", "where" => filter}) |> convert_children()
  end

  defp convert(%{} = map), do: convert_children(map)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other

  defp convert_children(map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)
end
