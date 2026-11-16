defmodule StarlightBot.Repo.Migrations.RefreshCaseMinCost do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM gift_plans WHERE data LIKE '%"when":"after"%'|)

    for [id, json] <- rows, data = Jason.decode!(json), converted = convert(data), converted != data do
      repo().query!("UPDATE gift_plans SET data = ? WHERE id = ?", [Jason.encode!(converted), id])
    end
  end

  def down, do: :ok

  defp convert(%{"refresh" => cases} = section) when is_list(cases) do
    section |> Map.put("refresh", Enum.map(cases, &convert_case/1)) |> convert_floors()
  end

  defp convert(%{} = map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other

  defp convert_floors(%{"refresh_floors" => floors} = section) when is_list(floors) do
    floors = Enum.map(floors, fn floor -> Map.update(floor, "cases", [], fn cases -> Enum.map(cases, &convert_case/1) end) end)
    %{section | "refresh_floors" => floors}
  end

  defp convert_floors(section), do: section

  defp convert_case(%{"condition" => %{"op" => "and", "children" => children} = condition} = refresh_case) do
    {bounds, rest} = Enum.split_with(children, &cost_after_bound?/1)

    case bounds do
      [] ->
        refresh_case

      _ ->
        min_cost = bounds |> Enum.map(& &1["value"]) |> Enum.max()
        condition = if rest == [], do: nil, else: %{condition | "children" => rest}
        refresh_case |> Map.put("condition", condition) |> Map.put("min_cost", min_cost)
    end
  end

  defp convert_case(refresh_case), do: refresh_case

  defp cost_after_bound?(%{"op" => "cost", "when" => "after", "cmp" => "gte", "value" => value} = leaf) when is_integer(value), do: leaf["not"] != true
  defp cost_after_bound?(_leaf), do: false
end
