defmodule StarlightBot.Repo.Migrations.ChainActionsToMode do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM battle_plans WHERE data LIKE '%"chain_fast"%' OR data LIKE '%"chain_a_res"%'|)

    for [id, json] <- rows do
      data = json |> Jason.decode!() |> convert()
      repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(data), id])
    end
  end

  def down, do: :ok

  defp convert(%{"type" => "chain_fast"} = action), do: convert_children(%{action | "type" => "chain"} |> Map.put("mode", "fast"))
  defp convert(%{"type" => "chain_a_res"} = action), do: convert_children(%{action | "type" => "chain"} |> Map.put("mode", "a_res"))
  defp convert(%{} = map), do: convert_children(map)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other

  defp convert_children(map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)
end
