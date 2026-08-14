defmodule StarlightBot.Automation.RunMemory do
  alias StarlightBot.Ctx

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
    update(ctx, :ego_gifts, %{}, &Map.put(&1, gift_id, gift_name))
  end

  def team(ctx), do: get(ctx, :team, nil)

  def put_team(ctx, team), do: put(ctx, :team, team)

  def team_affinity(ctx), do: (team(ctx) || %{})[:affinity]
end
