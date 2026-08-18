defmodule StarlightBot.ThemePackPlans.Resolver do
  alias StarlightBot.ThemePacks

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

  def priority_in_play?(plan_data, all_packs, mode, floor, priority) do
    packs_by_id = Map.new(all_packs, &{&1.id, &1})

    plan_data
    |> Map.get("packs", %{})
    |> Enum.any?(fn {pack_id, modes} ->
      with %{"priority" => ^priority} <- modes[mode],
           pack when not is_nil(pack) <- packs_by_id[pack_id] do
        floor in floors_for(plan_data, pack_id, mode, pack)
      else
        _ -> false
      end
    end)
  end

  def hunt_in_play?(plan_data, all_packs, mode, floor) do
    priority_in_play?(plan_data, all_packs, mode, floor, "hunt")
  end

  def choose(shown_packs, all_packs, plan_data, mode, floor, refreshes_left) do
    classified = Enum.map(shown_packs, &{&1.id, priority_at(plan_data, &1, mode, floor)})

    cond do
      bonus = Enum.find(classified, fn {_, p} -> p == "bonus" end) ->
        {:pick, elem(bonus, 0)}

      hunt = Enum.find(classified, fn {_, p} -> p == "hunt" end) ->
        {:pick, elem(hunt, 0)}

      fine = Enum.find(classified, fn {_, p} -> p == "fine" end) ->
        if refreshes_left > 0 and hunt_in_play?(plan_data, all_packs, mode, floor) do
          :refresh
        else
          {:pick, elem(fine, 0)}
        end

      refreshes_left > 0 ->
        :refresh

      true ->
        {forced_id, _} = hd(classified)
        {:forced_pick, forced_id}
    end
  end
end
