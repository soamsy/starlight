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

  @last_searchable_floor 10

  @mode_overrides ~w(default hard_1 hard_2 hard_3 hard_4 hard_5 extreme)

  def mode_overrides, do: @mode_overrides

  def parse_mode_override(value) when value in @mode_overrides, do: value
  def parse_mode_override(_value), do: "default"

  def with_mode_override(plan_data, "extreme") do
    plan_data |> Map.put("mode_schedule", [%{"from_floor" => 1, "mode" => "hard"}]) |> Map.put("extreme", true)
  end

  def with_mode_override(plan_data, "hard_" <> floor) when floor in ~w(1 2 3 4 5) do
    plan_data |> Map.put("mode_schedule", [%{"from_floor" => String.to_integer(floor), "mode" => "hard"}]) |> Map.put("extreme", false)
  end

  def with_mode_override(plan_data, _override), do: plan_data

  @search_overrides ~w(default all none)

  def search_overrides, do: @search_overrides

  def parse_search_override(value) when value in @search_overrides, do: value
  def parse_search_override(_value), do: "default"

  def with_search_override(plan_data, "all"), do: Map.put(plan_data, "search_floors", Enum.to_list(1..@last_searchable_floor))
  def with_search_override(plan_data, "none"), do: Map.put(plan_data, "search_floors", [])
  def with_search_override(plan_data, _override), do: plan_data


  def extreme_allowed?(plan_data), do: plan_data["mode_schedule"] == [%{"from_floor" => 1, "mode" => "hard"}]

  def full_hard?(plan_data), do: Enum.all?(1..5, &(mode_for_floor(plan_data["mode_schedule"] || [], &1) == "hard"))

  def extreme?(plan_data), do: plan_data["extreme"] == true and extreme_allowed?(plan_data)

  def run_kind(plan_data) do
    schedule = plan_data["mode_schedule"] || []

    cond do
      extreme?(plan_data) -> "extreme"
      mode_for_floor(schedule, 1) == "hard" -> "all_hard"
      Enum.any?(2..5, &(mode_for_floor(schedule, &1) == "hard")) -> "becomes_hard"
      true -> "all_normal"
    end
  end

  @extreme_override_pack "thm_116"

  def extreme_override?(plan_data, pack_id, mode), do: pack_id == @extreme_override_pack and mode == "hard" and extreme?(plan_data)

  def searchable_floor?(floor), do: floor <= @last_searchable_floor

  def eligible_floors(pack, "hard"), do: ThemePacks.decode_floors(pack.hard_floors)
  def eligible_floors(pack, "normal"), do: ThemePacks.decode_floors(pack.normal_floors)

  def status_at(plan_data, pack_id, mode, floor) do
    get_in(plan_data, ["packs", pack_id, mode, Integer.to_string(floor)]) || "none"
  end

  def priority_at(plan_data, pack, mode, floor) do
    case status_at(plan_data, pack.id, mode, floor) do
      status when status in ~w(favorite hunt) -> "hunt"
      "banned" -> "banned"
      _ -> "fine"
    end
  end

  def hunt_in_play?(plan_data, all_packs, mode, floor) do
    Enum.any?(all_packs, &(priority_at(plan_data, &1, mode, floor) == "hunt"))
  end

  def favorite?(plan_data, pack_id, mode, floor), do: status_at(plan_data, pack_id, mode, floor) == "favorite"

  def hunted_floors(plan_data, pack_id, mode) do
    floors = get_in(plan_data, ["packs", pack_id, mode]) || %{}
    for {floor, status} <- floors, status in ~w(favorite hunt), do: String.to_integer(floor)
  end

  def hunt_order(plan_data, mode, floor), do: get_in(plan_data, ["order", mode, Integer.to_string(floor)]) || []

  def hunt_rank(plan_data, mode, floor) do
    order = hunt_order(plan_data, mode, floor)
    ranks = order |> Enum.with_index() |> Map.new()
    &{if(favorite?(plan_data, &1, mode, floor), do: 0, else: 1), Map.get(ranks, &1, length(order))}
  end

  def sort_hunt(packs, plan_data, mode, floor) do
    rank = hunt_rank(plan_data, mode, floor)
    Enum.sort_by(packs, &rank.(&1.id))
  end

  def choose(shown_packs, all_packs, plan_data, mode, floor, refreshes_left) do
    classified = Enum.map(shown_packs, &{&1, priority_at(plan_data, &1, mode, floor)})
    hunt = for {pack, "hunt"} <- classified, do: pack

    cond do
      hunt != [] ->
        {:pick, hd(sort_hunt(hunt, plan_data, mode, floor)).id}

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
