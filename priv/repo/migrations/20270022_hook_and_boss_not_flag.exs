defmodule StarlightBot.Repo.Migrations.HookAndBossNotFlag do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM battle_plans WHERE data LIKE '%"hook_on"%' OR data LIKE '%"hook_off"%' OR data LIKE '%"not_boss_fight"%'|)

    for [id, json] <- rows do
      data = json |> Jason.decode!() |> convert()
      repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(data), id])
    end
  end

  def down, do: :ok

  defp convert(%{"op" => "hook_on"} = leaf), do: %{leaf | "op" => "hook"}
  defp convert(%{"op" => "hook_off"} = leaf), do: %{leaf | "op" => "hook"} |> Map.put("not", true)
  defp convert(%{"op" => "not_boss_fight"} = leaf), do: %{leaf | "op" => "boss_fight"} |> Map.put("not", true)
  defp convert(%{} = map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other
end
