defmodule StarlightBot.Automation.RunMemory do
  alias StarlightBot.Ctx
  alias StarlightBot.ThemePackPlans.Resolver
  alias StarlightBot.{Strategies, Teams}

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

  def ego_gifts(ctx), do: get(ctx, :ego_gifts, %{})

  def add_ego_gift(ctx, gift_id, gift_name) do
    update(ctx, :ego_gifts, %{}, fn gifts ->
      Map.update(gifts, gift_id, %{name: gift_name, uptie: 0}, &%{&1 | name: gift_name})
    end)
  end

  def set_ego_gift_uptie(ctx, gift_id, uptie) do
    update(ctx, :ego_gifts, %{}, fn gifts ->
      Map.update(gifts, gift_id, %{name: nil, uptie: uptie}, &%{&1 | uptie: max(&1.uptie, uptie)})
    end)
  end

  def remove_ego_gift(ctx, gift_id) do
    update(ctx, :ego_gifts, %{}, &Map.delete(&1, gift_id))
  end

  def team(ctx), do: get(ctx, :team, nil)

  def put_team(ctx, team), do: put(ctx, :team, team)

  def floor(ctx), do: get(ctx, :floor, 1)

  def put_floor(ctx, floor), do: put(ctx, :floor, floor)

  def cost(ctx), do: get(ctx, :cost, nil)

  def put_cost(ctx, cost), do: put(ctx, :cost, cost)

  def shop_plan(ctx), do: get(ctx, :shop_plan, nil)

  def put_shop_plan(ctx, plan), do: put(ctx, :shop_plan, plan)

  def gift_strategy(ctx) do
    with %{id: team_id} <- team(ctx),
         %{gift_strategy_id: id} when is_integer(id) <- Teams.get_team(team_id),
         %{data: data} when is_map(data) <- Strategies.get(:gift_strategies, id) do
      data
    else
      _ -> nil
    end
  end

  def context(ctx), do: get(ctx, :context, nil)

  def put_context(ctx, context), do: put(ctx, :context, context)

  def battle_strategy(ctx) do
    with %{id: team_id} <- team(ctx),
         %{battle_strategy_id: id} when is_integer(id) <- Teams.get_team(team_id),
         %{data: data} when is_map(data) <- Strategies.get(:battle_strategies, id) do
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

  def mode(ctx), do: get(ctx, :mode, nil) || mode_for(team(ctx), get(ctx, :floor, 1))

  def put_mode(ctx, mode), do: put(ctx, :mode, mode)

  def mode_for(%{id: team_id}, floor), do: Resolver.mode_for_floor(mode_schedule(team_id), floor)
  def mode_for(_team, _floor), do: "normal"

  defp mode_schedule(team_id) do
    with %{theme_pack_plan_id: id} when is_integer(id) <- Teams.get_team(team_id),
         %{data: %{"mode_schedule" => schedule}} when is_list(schedule) <- Strategies.get(:theme_pack_plans, id) do
      schedule
    else
      _ -> []
    end
  end
end
