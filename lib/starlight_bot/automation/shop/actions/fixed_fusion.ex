defmodule StarlightBot.Automation.Shop.Actions.FixedFusion do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Actions.Fusion
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def obtain(entry, step, state, ctx, stack) do
    with {:ok, target} <- recipe(entry, state) do
      if owned?(target.id, ctx),
        do: {:skipped, "#{target.name} already owned", state},
        else: gather(target, step, {[], []}, state, ctx, [entry.id | stack])
    end
  end

  defp recipe(entry, state) do
    case state.gifts_by_name[entry.gift] do
      nil -> {:failed, "#{entry.gift} isn't a known gift", state}
      target -> if GiftPlans.fixed_recipe?(target), do: {:ok, target}, else: {:failed, "#{target.name} has no fixed recipe", state}
    end
  end

  defp gather(target, step, {progress, attempted}, state, ctx, stack) do
    case missing(target, state, ctx) do
      {[], 0} ->
        fuse(target, progress, state, ctx)

      {missing_ids, fragments} ->
        case Ops.buy_missing_ids_from_shelf(buyable(missing_ids, fragments, state, ctx), ctx) do
          {:bought, item} -> gather(target, step, {progress ++ ["bought #{item.gift_name}"], attempted}, state, ctx, stack)
          _ -> fuse_missing(target, missing_ids, fragments, step, {progress, attempted}, state, ctx, stack)
        end
    end
  end

  defp missing(target, state, ctx) do
    {Enum.reject(GiftPlans.recipe_ids(target), &owned?(&1, ctx)), max(GiftPlans.fragment_slots(target) - length(owned_fragments(target, state, ctx)), 0)}
  end

  defp buyable(missing_ids, fragments, state, ctx) do
    named = Enum.filter(missing_ids, &(sibling(gift_name(&1, state), state)[:buy] == true))
    named ++ if(fragments > 0, do: fragment_ids(state, ctx, & &1.buy), else: [])
  end

  defp fuse_missing(target, missing_ids, fragments, step, {progress, attempted}, state, ctx, stack) do
    candidates = Enum.map(missing_ids, &gift_name(&1, state)) ++ if(fragments > 0, do: Enum.map(fragment_ids(state, ctx, & &1.fuse), &gift_name(&1, state)), else: [])

    routed =
      Enum.find_value(candidates, fn name ->
        sub = sibling(name, state)
        if sub && sub.fuse && sub.id not in stack && name not in attempted, do: sub
      end)

    case routed do
      nil ->
        give_up(missing_ids, fragments, progress, state)

      sub ->
        {_outcome, detail, state} = Fusion.obtain(sub, step, state, ctx, stack)
        tried = {progress ++ ["#{sub.gift}: #{detail}"], [sub.gift | attempted]}

        if owned_name?(sub.gift, ctx),
          do: gather(target, step, tried, state, ctx, stack),
          else: fuse_missing(target, missing_ids, fragments, step, tried, state, ctx, stack)
    end
  end

  defp fuse(target, progress, state, ctx) do
    ids = GiftPlans.recipe_ids(target) ++ Enum.take(owned_fragments(target, state, ctx), GiftPlans.fragment_slots(target))

    fusion_target = %{
      gift_name: target.name,
      affinity: target.affinity,
      fixed_id: target.id,
      shop_type: state.shop_type,
      chance_comet?: Ops.chance_comet_ready?(state.plan, target.tier || 0, ctx)
    }

    case Ops.perform_fusion(fusion_target, {:strict, ids}, ctx) do
      :ok -> {:done, Enum.join(progress ++ ["fused #{target.name}"], "; "), state}
      {:error, reason} -> finish(progress, "fusion failed: #{inspect(reason)}", state)
    end
  end

  defp give_up(missing_ids, fragments, progress, state) do
    names = Enum.map(missing_ids, &gift_name(&1, state)) ++ if(fragments > 0, do: ["#{fragments} Sin Fragment(s)"], else: [])
    finish(progress, "missing ingredients: #{Enum.join(names, ", ")}", state)
  end

  defp finish([], reason, state), do: {:failed, reason, state}
  defp finish(progress, reason, state), do: {:partial, Enum.join(progress, "; ") <> "; then " <> reason, state}

  defp owned_fragments(target, state, ctx) do
    recipe = GiftPlans.recipe_ids(target)

    for name <- GiftPlans.sin_fragments(), gift = state.gifts_by_name[name], gift.id not in recipe, owned?(gift.id, ctx), do: gift.id
  end

  defp fragment_ids(state, ctx, wanted?) do
    for name <- GiftPlans.sin_fragments(), gift = state.gifts_by_name[name], not owned?(gift.id, ctx), sub = sibling(name, state), wanted?.(sub), do: gift.id
  end

  defp sibling(name, state), do: Enum.find(Map.get(state, :milestone_entries, []), &(&1.gift == name))

  defp gift_name(id, state), do: (state.gifts_by_id[id] && state.gifts_by_id[id].name) || id

  defp owned?(gift_id, ctx), do: Map.has_key?(RunMemory.ego_gifts(ctx), gift_id)

  defp owned_name?(name, ctx), do: ctx |> RunMemory.ego_gifts() |> Enum.any?(fn {_id, entry} -> entry.name == name end)
end
