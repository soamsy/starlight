defmodule StarlightBot.Automation.Shop.Actions.FixedFusion do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Actions.Fusion
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def obtain(definition, step, state, ctx, stack) do
    with {:ok, target, ingredient_ids} <- recipe(definition, state) do
      if owned?(target.id, ctx),
        do: {:skipped, "#{target.name} already owned", state},
        else: gather(definition, target, ingredient_ids, step, {[], []}, state, ctx, [definition["id"] | stack])
    end
  end

  def preview(definition, state, ctx) do
    with {:ok, target, ingredient_ids} <- recipe(definition, state) do
      plan =
        ingredient_ids
        |> Enum.reject(&owned?(&1, ctx))
        |> Enum.map(fn id ->
          name = gift_name(id, state)

          case sub_fusion(definition, name, state) do
            nil -> if definition["buy_missing"] != false, do: "buy #{name}", else: "#{name} missing"
            sub -> "buy or fuse #{name} (#{sub["name"]})"
          end
        end)

      detail = if plan == [], do: "would fuse #{target.name}", else: "#{target.name}: #{Enum.join(plan, ", ")}, then fuse"
      {:would_run, detail, state}
    end
  end

  defp recipe(definition, state) do
    case state.gifts_by_name[definition["target"]] do
      nil ->
        {:failed, "#{definition["name"]} has no target set", state}

      target ->
        case GiftPlans.ingredient_ids(target) do
          [] -> {:failed, "#{target.name} has no fixed recipe", state}
          ids -> {:ok, target, ids}
        end
    end
  end

  defp gather(definition, target, ingredient_ids, step, {progress, attempted}, state, ctx, stack) do
    case missing(ingredient_ids, ctx) do
      [] ->
        fuse(target, ingredient_ids, progress, state, ctx)

      missing_ids ->
        with true <- definition["buy_missing"] != false,
             {:bought, item} <- Ops.buy_missing_ids_from_shelf(missing_ids, ctx) do
          gather(definition, target, ingredient_ids, step, {progress ++ ["bought #{item.gift_name}"], attempted}, state, ctx, stack)
        else
          _ -> fuse_missing(definition, target, ingredient_ids, missing_ids, step, {progress, attempted}, state, ctx, stack)
        end
    end
  end

  defp fuse_missing(definition, target, ingredient_ids, missing_ids, step, {progress, attempted}, state, ctx, stack) do
    routed =
      Enum.find_value(missing_ids, fn id ->
        sub = sub_fusion(definition, gift_name(id, state), state)
        if sub && sub["id"] not in stack && id not in attempted, do: {id, sub}
      end)

    case routed do
      nil ->
        give_up(missing_ids, progress, state)

      {id, sub} ->
        {_outcome, detail, state} = Fusion.obtain(sub, step, state, ctx, stack)
        tried = {progress ++ ["#{sub["name"]}: #{detail}"], [id | attempted]}

        if owned?(id, ctx),
          do: gather(definition, target, ingredient_ids, step, tried, state, ctx, stack),
          else: fuse_missing(definition, target, ingredient_ids, missing_ids, step, tried, state, ctx, stack)
    end
  end

  defp fuse(target, ingredient_ids, progress, state, ctx) do
    fusion_target = %{
      gift_name: target.name,
      affinity: target.affinity,
      fixed_id: target.id,
      chance_comet?: Ops.chance_comet_ready?(state.plan, target.tier || 0, ctx)
    }

    case Ops.perform_fusion(fusion_target, {:strict, ingredient_ids}, ctx) do
      :ok -> {:done, Enum.join(progress ++ ["fused #{target.name}"], "; "), state}
      {:error, reason} -> finish(progress, "fusion failed: #{inspect(reason)}", state)
    end
  end

  defp give_up(missing_ids, progress, state) do
    finish(progress, "missing ingredients: #{Enum.map_join(missing_ids, ", ", &gift_name(&1, state))}", state)
  end

  defp finish([], reason, state), do: {:failed, reason, state}
  defp finish(progress, reason, state), do: {:partial, Enum.join(progress, "; ") <> "; then " <> reason, state}

  defp sub_fusion(definition, ingredient_name, state) do
    case (definition["sub_fusions"] || %{})[ingredient_name] do
      nil -> nil
      id -> GiftPlans.find_definition(state.plan, "fusions", id)
    end
  end

  defp gift_name(id, state), do: (state.gifts_by_id[id] && state.gifts_by_id[id].name) || id

  defp missing(ingredient_ids, ctx), do: Enum.reject(ingredient_ids, &owned?(&1, ctx))

  defp owned?(gift_id, ctx), do: Map.has_key?(RunMemory.ego_gifts(ctx), gift_id)
end
