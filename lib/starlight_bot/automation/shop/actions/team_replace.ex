defmodule StarlightBot.Automation.Shop.Actions.TeamReplace do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.{Ctx, GiftPlans, SinnerProfiles}
  alias StarlightBot.Vision.HookRegistry

  def pending(entries, state, ctx) do
    done = Map.get(state, :team_replaced, MapSet.new())
    memory = RunMemory.team_replaces(ctx)

    entries
    |> GiftPlans.team_replace_entries()
    |> Enum.flat_map(& &1.replacements)
    |> Enum.filter(&is_integer(&1["profile"]))
    |> Enum.uniq_by(& &1["sinner"])
    |> Enum.reject(&(MapSet.member?(done, &1["sinner"]) or memory[&1["sinner"]] == &1["profile"]))
    |> Enum.take(GiftPlans.team_replace_max() - MapSet.size(done))
  end

  def run_entries(entries, state, ctx) do
    case pending(entries, state, ctx) do
      [] -> {[], false, state}
      targets -> run_targets(targets, state, ctx)
    end
  end

  defp run_targets(targets, state, ctx) do
    if Ops.team_replace_offered?() do
      case Ops.open_team_replace(ctx) do
        :ok -> replace_each(targets, {[], false, state}, ctx)
        {:error, reason} -> {["team replace: couldn't open it (#{inspect(reason)})"], false, state}
      end
    else
      {["team replace: not offered in this shop"], false, state}
    end
  end

  defp replace_each(targets, acc, ctx) do
    {lines, acted?, state} = Enum.reduce_while(targets, acc, &replace_one(&1, &2, ctx))
    Ops.close_team_replace(ctx)
    Ops.detect_and_update_cost(ctx)
    {lines, acted?, state}
  end

  defp replace_one(%{"sinner" => sinner, "profile" => profile_id}, {lines, acted?, state}, ctx) do
    profile = Enum.find(SinnerProfiles.list(), &(&1.id == profile_id))

    cost = RunMemory.cost(ctx)
    unaffordable? = is_integer(cost) and cost < GiftPlans.team_replace_cost()

    case {unaffordable?, hooks(profile)} do
      {true, _} ->
        {:cont, {lines ++ ["team replace: cost #{cost} is below #{GiftPlans.team_replace_cost()}, skipping #{sinner}"], acted?, state}}

      {false, []} ->
        {:cont, {lines ++ ["team replace: #{profile_label(profile, profile_id)} has no HD hook"], acted?, state}}

      {false, hooks} ->
        case Ops.pick_team_replacement(sinner, hooks, ctx) do
          :ok ->
            RunMemory.put_team_replace(ctx, sinner, profile_id)
            if is_integer(cost), do: RunMemory.put_cost(ctx, cost - GiftPlans.team_replace_cost())
            state = Map.update(state, :team_replaced, MapSet.new([sinner]), &MapSet.put(&1, sinner))
            {:cont, {lines ++ ["replaced #{sinner} with #{profile.name}"], true, state}}

          {:error, :profile_not_found} ->
            Ctx.log(ctx, :info, "team replace: #{profile.name} not in #{sinner}'s catalog")
            {:cont, {lines ++ ["team replace: couldn't find #{profile.name} for #{sinner}"], acted?, state}}

          {:error, reason} ->
            {:halt, {lines ++ ["team replace: #{sinner} failed (#{inspect(reason)})"], acted?, state}}
        end
    end
  end

  defp hooks(nil), do: []

  defp hooks(profile) do
    loaded = Map.new(HookRegistry.all_names(), &{Atom.to_string(&1), &1})
    for name <- [profile.hd_locator_hook, profile.hd_base_locator_hook], is_binary(name), atom = loaded[name], not is_nil(atom), do: atom
  end

  defp profile_label(nil, id), do: "profile #{id}"
  defp profile_label(profile, _id), do: profile.name

  def preview_labels(entries, state, ctx), do: entries |> pending(state, ctx) |> Enum.map(& &1["sinner"])
end
