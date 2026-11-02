defmodule StarlightBot.PackPlans.Legacy do
  @modes ~w(normal hard)
  @floors 1..15

  def legacy?(%{"version" => 2}), do: false
  def legacy?(%{"packs" => _}), do: true
  def legacy?(_data), do: false

  def upgrade(data, eligible) do
    if legacy?(data), do: convert(data, eligible), else: data
  end

  def convert(data, eligible) do
    statuses = for {id, modes} <- data["packs"] || %{}, is_map(modes), mode <- @modes, is_map(modes[mode]), do: {id, mode, modes[mode]}

    packs =
      Enum.reduce(statuses, %{}, fn {id, mode, entry}, acc ->
        case floor_statuses(entry, eligible.(id, mode)) do
          floors when map_size(floors) == 0 -> acc
          floors -> put_in(acc, [Access.key(id, %{}), mode], floors)
        end
      end)

    data
    |> Map.drop(["hunt_order"])
    |> Map.put("version", 2)
    |> Map.put("packs", packs)
    |> put_order(packs, data["hunt_order"] || %{})
  end

  defp floor_statuses(%{"priority" => priority} = entry, eligible) when priority in ~w(hunt banned) do
    status = if priority == "hunt" and entry["favorite"] == true, do: "favorite", else: priority
    floors = if is_list(entry["floors"]), do: entry["floors"], else: if(eligible == [], do: Enum.to_list(@floors), else: eligible)
    Map.new(floors, &{Integer.to_string(&1), status})
  end

  defp floor_statuses(_entry, _eligible), do: %{}

  defp put_order(data, packs, hunt_order) do
    order =
      for mode <- @modes,
          floor <- @floors,
          key = Integer.to_string(floor),
          hunted = hunted_ids(packs, mode, key),
          hunted != [],
          reduce: %{} do
        acc -> put_in(acc, [Access.key(mode, %{}), key], ranked(hunted, hunt_order[mode] || []))
      end

    if order == %{}, do: Map.delete(data, "order"), else: Map.put(data, "order", order)
  end

  defp hunted_ids(packs, mode, key) do
    for {id, modes} <- packs, modes[mode][key] in ~w(hunt favorite), do: id
  end

  defp ranked(ids, order), do: Enum.filter(order, &(&1 in ids)) ++ Enum.sort(ids -- order)
end
