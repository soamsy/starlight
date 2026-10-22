defmodule StarlightBot.PackPlans.Resolver do
  alias StarlightBot.ThemePacks

  def mode_for_floor(mode_schedule, floor) when is_list(mode_schedule) and is_integer(floor) and floor > 5, do: "hard"

  def mode_for_floor(mode_schedule, floor) when is_list(mode_schedule) and is_integer(floor) do
    mode_schedule
    |> Enum.filter(&(&1["from_floor"] <= floor))
    |> Enum.max_by(& &1["from_floor"], fn -> nil end)
    |> case do
      nil -> "normal"
      %{"mode" => mode} -> mode
    end
  end

  def eligible_floors(pack, "hard"), do: ThemePacks.decode_floors(pack.hard_floors)
  def eligible_floors(pack, "normal"), do: ThemePacks.decode_floors(pack.normal_floors)

  def priority_for(plan_data, pack_id, mode) do
    get_in(plan_data, ["packs", pack_id, mode, "priority"]) || "fine"
  end

  def floors_for(plan_data, pack_id, mode, pack) do
    case get_in(plan_data, ["packs", pack_id, mode, "floors"]) do
      floors when is_list(floors) -> floors
      _ -> eligible_floors(pack, mode)
    end
  end

  def priority_at(plan_data, pack, mode, floor) do
    priority = priority_for(plan_data, pack.id, mode)

    if priority == "fine" or floor in floors_for(plan_data, pack.id, mode, pack) do
      priority
    else
      "fine"
    end
  end

  def hunt_in_play?(plan_data, all_packs, mode, floor) do
    Enum.any?(all_packs, &(priority_at(plan_data, &1, mode, floor) == "hunt" and not chance?(plan_data, &1.id, mode)))
  end

  def chance?(plan_data, pack_id, mode) do
    get_in(plan_data, ["packs", pack_id, mode, "chance"]) == true
  end

  def hunt_rank(plan_data, mode) do
    order = get_in(plan_data, ["hunt_order", mode]) || []
    ranks = order |> Enum.with_index() |> Map.new()
    &Map.get(ranks, &1, length(order))
  end

  def sort_hunt(packs, plan_data, mode) do
    rank = hunt_rank(plan_data, mode)
    Enum.sort_by(packs, &rank.(&1.id))
  end

  def choose(shown_packs, all_packs, plan_data, mode, floor, refreshes_left) do
    classified = Enum.map(shown_packs, &{&1, priority_at(plan_data, &1, mode, floor)})
    hunt = for {pack, "hunt"} <- classified, do: pack

    cond do
      hunt != [] ->
        {:pick, hd(sort_hunt(hunt, plan_data, mode)).id}

      fine = Enum.find(classified, fn {_, p} -> p == "fine" end) ->
        if refreshes_left > 0 and hunt_in_play?(plan_data, all_packs, mode, floor) do
          :refresh
        else
          {:pick, elem(fine, 0).id}
        end

      refreshes_left > 0 ->
        :refresh

      true ->
        {forced, _} = hd(classified)
        {:forced_pick, forced.id}
    end
  end
end
