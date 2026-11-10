defmodule StarlightBot.Repo.Migrations.ConditionLeavesMultiSelect do
  use Ecto.Migration

  @sinner_ops %{"sinners_eq" => "eq", "sinners_gte" => "gte", "sinners_lte" => "lte"}

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM battle_plans WHERE data LIKE '%"tray_count"%' OR data LIKE '%"sinners_%'|)

    for [id, json] <- rows do
      data = json |> Jason.decode!() |> convert()
      repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(data), id])
    end
  end

  def down, do: :ok

  defp convert(%{"op" => op} = leaf) when is_map_key(@sinner_ops, op), do: %{"op" => "sinner_count", "cmp" => @sinner_ops[op], "value" => leaf["value"]}

  defp convert(%{"op" => "tray_count"} = leaf) do
    sinners = if is_binary(leaf["sinner"]), do: [leaf["sinner"]], else: Map.get(leaf, "sinners", [])
    matches = if leaf["match"] in [nil, "any"], do: Map.get(leaf, "matches", []), else: [leaf["match"]]

    leaf |> Map.drop(["sinner", "match"]) |> Map.merge(%{"sinners" => sinners, "matches" => matches})
  end

  defp convert(%{} = map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other
end
