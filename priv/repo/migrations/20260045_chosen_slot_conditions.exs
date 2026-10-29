defmodule StarlightBot.Repo.Migrations.ChosenSlotConditions do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!("SELECT id, data FROM battle_plans")

    Enum.each(rows, fn [id, json] ->
      with {:ok, %{} = data} <- Jason.decode(json || "") do
        upgraded = upgrade(data)

        if upgraded != data do
          repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(upgraded), id])
        end
      end
    end)
  end

  def down, do: :ok

  defp upgrade(%{"chosen" => %{"is" => is?}} = holder) when is_boolean(is?) do
    holder |> Map.put("chosen", filter(%{"kind" => if(is?, do: "bottom", else: "top")})) |> upgrade_children()
  end

  defp upgrade(%{"chosen" => %{"using" => using?, "match" => match}} = holder) do
    condition = %{"kind" => if(using?, do: "using", else: "not_using"), "values" => [match]}
    holder |> Map.put("chosen", filter(condition)) |> upgrade_children()
  end

  defp upgrade(%{} = map), do: upgrade_children(map)
  defp upgrade(list) when is_list(list), do: Enum.map(list, &upgrade/1)
  defp upgrade(value), do: value

  defp upgrade_children(map), do: Map.new(map, fn {key, value} -> {key, if(key == "chosen", do: value, else: upgrade(value))} end)

  defp filter(condition), do: %{"join" => "and", "conditions" => [condition]}
end
