defmodule StarlightBot.Repo.Migrations.EnemySlotToOffset do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM battle_plans WHERE data LIKE '%"enemy"%'|)

    for [id, json] <- rows do
      data = json |> Jason.decode!() |> convert()
      repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(data), id])
    end
  end

  def down, do: :ok

  defp convert(%{"enemy" => %{"pick" => pick, "n" => n} = enemy} = map) when pick in ["first", "last"] do
    enemy = enemy |> Map.delete("n") |> Map.put("offset", max((if is_integer(n), do: n, else: 1) - 1, 0))
    map |> Map.put("enemy", enemy) |> convert_children()
  end

  defp convert(%{"enemy" => %{"pick" => pick, "n" => _} = enemy} = map) when pick in ["exact", "up_to", "percent"] do
    map |> Map.put("enemy", enemy |> Map.delete("n") |> Map.put("pick", "first") |> Map.put("offset", 0)) |> convert_children()
  end

  defp convert(%{} = map), do: convert_children(map)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other

  defp convert_children(map), do: Map.new(map, fn {key, value} -> {key, if(key == "enemy", do: value, else: convert(value))} end)
end
