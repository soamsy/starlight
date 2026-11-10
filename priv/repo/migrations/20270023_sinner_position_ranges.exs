defmodule StarlightBot.Repo.Migrations.SinnerPositionRanges do
  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!(~s|SELECT id, data FROM battle_plans WHERE data LIKE '%"sinner_position"%'|)

    for [id, json] <- rows do
      data = json |> Jason.decode!() |> convert()
      repo().query!("UPDATE battle_plans SET data = ? WHERE id = ?", [Jason.encode!(data), id])
    end
  end

  def down, do: :ok

  defp convert(%{"op" => "sinner_position", "cmp" => cmp} = leaf) do
    sinners = if is_binary(leaf["sinner"]), do: [leaf["sinner"]], else: []
    leaf = %{"op" => "sinner_position", "sinners" => sinners, "position" => position(leaf["pos"], leaf["value"], cmp)}
    if cmp == "is_not", do: Map.put(leaf, "not", true), else: leaf
  end

  defp convert(%{} = map), do: Map.new(map, fn {key, value} -> {key, convert(value)} end)
  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(other), do: other

  defp position(pos, value, cmp) when cmp in ["is", "is_not"], do: slots(pick(pos), at(pos, value), true, false, false)
  defp position("last", _value, "gt"), do: slots("last", 0, false, false, false)
  defp position("last", _value, "lt"), do: slots("last", 0, false, false, true)
  defp position(pos, value, "gt"), do: slots("first", at(pos, value), false, false, true)
  defp position(pos, value, "lt"), do: slots("first", at(pos, value), false, true, false)

  defp pick("last"), do: "last"
  defp pick(_pos), do: "first"

  defp at("exact", value), do: max((value || 1) - 1, 0)
  defp at(_pos, _value), do: 0

  defp slots(pick, at, on, lead, trail) do
    %{"pick" => pick, "chips" => [%{"at" => at, "on" => on}], "gaps" => %{"lead" => lead, "mid" => [], "trail" => trail}}
  end
end
