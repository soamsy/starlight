defmodule StarlightBot.Automation.RunMemory do
  alias StarlightBot.Ctx
  alias StarlightBot.PackPlans.Resolver
  alias StarlightBot.{BattlePlans, Plans, Teams}

  def start_link, do: Agent.start_link(fn -> %{} end)

  def stop(%Ctx{run_memory: nil}), do: :ok
  def stop(%Ctx{run_memory: pid}), do: Agent.stop(pid)

  def get(%Ctx{run_memory: nil}, _key, default), do: default
  def get(%Ctx{run_memory: pid}, key, default), do: Agent.get(pid, &Map.get(&1, key, default))

  def update(%Ctx{run_memory: nil}, _key, default, fun), do: fun.(default)

  def update(%Ctx{run_memory: pid} = ctx, key, default, fun) do
    {new_val, snapshot} =
      Agent.get_and_update(pid, fn state ->
        updated_val = fun.(Map.get(state, key, default))
        new_state = Map.put(state, key, updated_val)
        {{updated_val, new_state}, new_state}
      end)

    Ctx.run_memory_changed(ctx, snapshot)
    new_val
  end

  def put(ctx, key, value), do: update(ctx, key, value, fn _ -> value end)

  def merge(%Ctx{run_memory: nil}, _values), do: :ok

  def merge(%Ctx{run_memory: pid} = ctx, values) do
    snapshot = Agent.get_and_update(pid, fn state -> state |> Map.merge(values) |> then(&{&1, &1}) end)
    Ctx.run_memory_changed(ctx, snapshot)
    :ok
  end

  def ego_gifts(ctx), do: get(ctx, :ego_gifts, %{})

  def add_ego_gift(ctx, gift_id, gift_name) do
    before = ego_gifts(ctx)

    gifts_after =
      update(ctx, :ego_gifts, %{}, fn gifts ->
        Map.update(gifts, gift_id, %{name: gift_name, uptie: 0, count: 1}, &%{&1 | name: gift_name})
      end)

    unless Map.has_key?(before, gift_id), do: log_inventory(ctx, "+ #{gift_name} (#{gift_id})", gifts_after)
    gifts_after
  end

  def ego_gift_count(ctx, gift_id) do
    case ego_gifts(ctx)[gift_id] do
      nil -> 0
      gift -> gift.count
    end
  end

  def observe_ego_gift_count(ctx, gift_id, gift_name, count) do
    add_ego_gift(ctx, gift_id, gift_name)
    if count > ego_gift_count(ctx, gift_id), do: set_ego_gift_count(ctx, gift_id, count), else: ego_gifts(ctx)
  end

  def set_ego_gift_count(ctx, gift_id, count) do
    old_count = ego_gift_count(ctx, gift_id)
    gifts_after = update(ctx, :ego_gifts, %{}, &Map.update!(&1, gift_id, fn gift -> %{gift | count: count} end))

    if count != old_count,
      do: log_inventory(ctx, "#{gifts_after[gift_id].name || gift_id} count #{old_count} -> #{count}", gifts_after)

    gifts_after
  end

  def set_ego_gift_uptie(ctx, gift_id, uptie) do
    old_uptie = get_in(ego_gifts(ctx), [gift_id, :uptie])

    gifts_after =
      update(ctx, :ego_gifts, %{}, fn gifts ->
        Map.update(gifts, gift_id, %{name: nil, uptie: uptie, count: 1}, &%{&1 | uptie: max(&1.uptie, uptie)})
      end)

    new_uptie = gifts_after[gift_id].uptie

    if new_uptie != old_uptie,
      do: log_inventory(ctx, "#{gifts_after[gift_id].name || gift_id} uptie #{old_uptie || "unknown"} -> #{new_uptie}", gifts_after)

    gifts_after
  end

  def remove_ego_gift(ctx, gift_id) do
    removed = ego_gifts(ctx)[gift_id]

    gifts_after =
      update(ctx, :ego_gifts, %{}, fn gifts ->
        case gifts[gift_id] do
          %{count: count} = gift when count > 1 -> Map.put(gifts, gift_id, %{gift | count: count - 1})
          _ -> Map.delete(gifts, gift_id)
        end
      end)

    if removed, do: log_inventory(ctx, "- #{removed.name || gift_id} (#{gift_id})", gifts_after)
    gifts_after
  end

  def skill_replaces(ctx), do: get(ctx, :skill_replaces, %{})

  def add_skill_replace(ctx, sinner, option) do
    update(ctx, :skill_replaces, %{}, fn replaces ->
      Map.update(replaces, sinner, %{option => 1}, &Map.update(&1, option, 1, fn count -> count + 1 end))
    end)
  end

  def unfusable_gifts(ctx), do: get(ctx, :unfusable_gifts, MapSet.new())

  def add_unfusable_gifts(ctx, gift_ids), do: update(ctx, :unfusable_gifts, MapSet.new(), &MapSet.union(&1, MapSet.new(gift_ids)))

  defp log_inventory(ctx, change, gifts), do: Ctx.log(ctx, :info, "inventory: #{change}, now #{map_size(gifts)} gift(s)")

  def team(ctx), do: get(ctx, :team, nil)

  def put_team(ctx, team), do: put(ctx, :team, team)

  def floor(ctx), do: get(ctx, :floor, 1)

  def put_floor(ctx, floor) do
    put_bosses_only(ctx, false)
    put(ctx, :floor, floor)
  end

  def bosses_only?(ctx), do: get(ctx, :bosses_only, false)

  def put_bosses_only(ctx, bosses_only), do: put(ctx, :bosses_only, bosses_only)

  def venue(ctx), do: get(ctx, :venue, "md_battle")

  def put_venue(ctx, venue), do: put(ctx, :venue, venue)

  def formation(ctx), do: get(ctx, :formation, nil)

  def put_formation(ctx, formation), do: put(ctx, :formation, formation)

  def raise_floor(ctx, read) do
    current = get(ctx, :floor, 1)

    if read < current do
      Ctx.log(ctx, :info, "floor read as #{read} but already on #{current}, keeping #{current}")
      current
    else
      if read > current, do: put_bosses_only(ctx, false)
      update(ctx, :floor, read, &max(&1, read))
    end
  end

  def dungeon_map(ctx), do: get(ctx, :dungeon_map, nil)

  def put_dungeon_map(ctx, map), do: put(ctx, :dungeon_map, map)

  def visited_packs(ctx), do: get(ctx, :visited_packs, [])

  def add_visited_pack(ctx, pack_id) do
    update(ctx, :visited_packs, [], fn visited -> if pack_id in visited, do: visited, else: visited ++ [pack_id] end)
  end

  def add_picked_pack(ctx, pack_name) do
    key = {get(ctx, :run_progress, %{})[:current], get(ctx, :floor, 1)}
    update(ctx, :picked_packs, %{}, &Map.put(&1, key, pack_name))
  end

  def cost(ctx), do: get(ctx, :cost, nil)

  def put_cost(ctx, cost), do: put(ctx, :cost, cost)

  def shop_plan(ctx), do: get(ctx, :shop_plan, nil)

  def put_shop_plan(ctx, plan), do: put(ctx, :shop_plan, plan)

  def shop_progress(ctx), do: get(ctx, :shop_progress, nil)

  def put_shop_progress(ctx, progress), do: put(ctx, :shop_progress, progress)

  def clear_shop_progress(ctx) do
    if shop_progress(ctx), do: put(ctx, :shop_progress, nil), else: :ok
  end

  def gift_plan(ctx) do
    with %{id: team_id} <- team(ctx),
         %{gift_plan_id: id} when is_integer(id) <- Teams.get_team(team_id),
         %{data: data} when is_map(data) <- Plans.get(:gift_plans, id) do
      data
    else
      _ -> nil
    end
  end

  def context(ctx), do: get(ctx, :context, nil)

  def put_context(ctx, context), do: put(ctx, :context, context)

  def battle_plan(ctx) do
    with %{id: team_id} <- team(ctx),
         %{battle_plan_id: id} when is_integer(id) <- Teams.get_team(team_id),
         %{data: data} when is_map(data) <- Plans.get(:battle_plans, id) do
      data
    else
      _ -> nil
    end
  end

  def battle_track(ctx, kind) do
    case context(ctx) do
      :luxcavation -> "lux_" <> kind
      _ -> mode(ctx) <> "_" <> kind
    end
  end

  def battle_turn(ctx), do: get(ctx, :battle_turn, 1)

  def put_battle_turn(ctx, turn), do: put(ctx, :battle_turn, turn)

  def battle_retries(ctx), do: get(ctx, :battle_retries, 0)

  def put_battle_retries(ctx, retries), do: put(ctx, :battle_retries, retries)

  def reset_battle_retries(ctx) do
    if battle_retries(ctx) != 0, do: put_battle_retries(ctx, 0)
    :ok
  end

  def give_up(ctx), do: get(ctx, :give_up, nil)

  def give_up?(ctx), do: give_up(ctx) != nil

  def put_give_up(ctx, reason), do: put(ctx, :give_up, reason)

  def claim_battle_retry(ctx) do
    retries = battle_retries(ctx)
    max_retries = BattlePlans.max_retries(battle_plan(ctx))

    cond do
      give_up?(ctx) ->
        :give_up

      retries < max_retries ->
        put_battle_retries(ctx, retries + 1)
        put_battle_turn(ctx, 1)
        {:retry, retries + 1, max_retries}

      true ->
        put_give_up(ctx, :too_many_retries)
        :give_up
    end
  end

  def mode(ctx), do: get(ctx, :mode, nil) || mode_for(team(ctx), get(ctx, :floor, 1))

  def put_mode(ctx, mode), do: put(ctx, :mode, mode)

  def mode_for(%{id: team_id}, floor), do: Resolver.mode_for_floor(mode_schedule(team_id), floor)
  def mode_for(_team, _floor), do: "normal"

  def extreme?(team_id), do: team_id |> pack_plan_data() |> Resolver.extreme?()

  defp mode_schedule(team_id), do: Map.get(pack_plan_data(team_id), "mode_schedule", [])

  defp pack_plan_data(team_id) do
    with %{pack_plan_id: id} when is_integer(id) <- Teams.get_team(team_id),
         %{data: %{"mode_schedule" => schedule} = data} when is_list(schedule) <- Plans.get(:pack_plans, id) do
      data
    else
      _ -> %{}
    end
  end
end
