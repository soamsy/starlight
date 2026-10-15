defmodule StarlightBot.GiftPlans.Routes do
  alias StarlightBot.GiftPlans.Combos

  def new(combo, opts \\ []) do
    %{
      "id" => new_id(),
      "combo" => combo,
      "buy_up_to" => Keyword.get(opts, :buy_up_to),
      "leftover" => Keyword.get(opts, :leftover, %{}),
      "subgoals" => Keyword.get(opts, :subgoals, %{})
    }
  end

  def defaults(4) do
    [
      new([3, 3, 2], buy_up_to: 3, subgoals: %{"3" => [new([2, 2, 2], leftover: %{"2" => 1})]}),
      new([4, 2, 2])
    ]
  end

  def defaults(_tier), do: []

  def subgoal_tiers(combo), do: combo |> Enum.uniq() |> Enum.filter(&(&1 >= 2)) |> Enum.sort(:desc)

  def subgoals_for(route, tier), do: Map.get(route["subgoals"] || %{}, Integer.to_string(tier), [])

  def leftover_for(route, tier), do: Map.get(route["leftover"] || %{}, Integer.to_string(tier), 0)

  def update(routes, id, fun) do
    Enum.map(routes, fn route ->
      if route["id"] == id, do: fun.(route), else: map_subgoals(route, &update(&1, id, fun))
    end)
  end

  def delete(routes, id) do
    routes
    |> Enum.reject(&(&1["id"] == id))
    |> Enum.map(fn route -> map_subgoals(route, &delete(&1, id)) end)
  end

  def duplicate(routes, id) do
    case Enum.find_index(routes, &(&1["id"] == id)) do
      nil -> Enum.map(routes, fn route -> map_subgoals(route, &duplicate(&1, id)) end)
      index -> List.insert_at(routes, index + 1, reassign_ids(Enum.at(routes, index)))
    end
  end

  def copy(routes), do: Enum.map(routes, &reassign_ids/1)

  def add(routes, nil, _tier, route), do: routes ++ [route]

  def add(routes, parent_id, tier, route) do
    update(routes, parent_id, fn parent ->
      key = Integer.to_string(tier)
      subgoals = parent["subgoals"] || %{}
      Map.put(parent, "subgoals", Map.put(subgoals, key, Map.get(subgoals, key, []) ++ [route]))
    end)
  end

  def reorder(routes, nil, _tier, ids), do: reorder_list(routes, ids)

  def reorder(routes, parent_id, tier, ids) do
    update(routes, parent_id, fn parent ->
      key = Integer.to_string(tier)
      Map.update(parent, "subgoals", %{}, &Map.update(&1, key, [], fn list -> reorder_list(list, ids) end))
    end)
  end

  def valid_for_tier(routes, tier) do
    valid = tier |> Combos.valid_combos() |> MapSet.new(& &1.combo)
    Enum.filter(routes, &MapSet.member?(valid, &1["combo"]))
  end

  def invalid_count(routes, tier) do
    valid = tier |> Combos.valid_combos() |> MapSet.new(& &1.combo)

    Enum.reduce(routes, 0, fn route, acc ->
      own = if MapSet.member?(valid, route["combo"]), do: 0, else: 1

      nested =
        route["subgoals"]
        |> Kernel.||(%{})
        |> Enum.map(fn {sub_tier, list} -> invalid_count(list, String.to_integer(sub_tier)) end)
        |> Enum.sum()

      acc + own + nested
    end)
  end

  def label(route) do
    flags =
      [
        route["buy_up_to"] && "buy ≤T#{route["buy_up_to"]}",
        leftover_label(route["leftover"] || %{}),
        subgoal_label(route["subgoals"] || %{})
      ]
      |> Enum.filter(& &1)

    suffix = if flags == [], do: "", else: " (#{Enum.join(flags, ", ")})"
    Combos.combo_key(route["combo"]) <> suffix
  end

  defp leftover_label(leftover) do
    case leftover |> Enum.filter(fn {_tier, count} -> count > 0 end) |> Enum.sort(:desc) do
      [] -> nil
      parts -> "leave " <> Enum.map_join(parts, " ", fn {tier, count} -> "#{count}×T#{tier}" end)
    end
  end

  defp subgoal_label(subgoals) do
    case subgoals |> Enum.reject(fn {_tier, list} -> list == [] end) |> Enum.map(&elem(&1, 0)) |> Enum.sort(:desc) do
      [] -> nil
      tiers -> "sub " <> Enum.map_join(tiers, " ", &"T#{&1}")
    end
  end

  defp map_subgoals(route, fun) do
    case route["subgoals"] do
      subgoals when is_map(subgoals) and map_size(subgoals) > 0 ->
        Map.put(route, "subgoals", Map.new(subgoals, fn {tier, list} -> {tier, fun.(list)} end))

      _ ->
        route
    end
  end

  defp reassign_ids(route) do
    route
    |> Map.put("id", new_id())
    |> map_subgoals(fn list -> Enum.map(list, &reassign_ids/1) end)
  end

  defp reorder_list(list, ids) do
    by_id = Map.new(list, &{&1["id"], &1})
    ordered = ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
    ordered ++ Enum.reject(list, &(&1 in ordered))
  end

  defp new_id, do: "rt_" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)
end
