defmodule StarlightBot.Automation.Shop.Actions.FixedFusion do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def run(step, _definition, state, ctx) do
    case Map.get(state.gifts_by_name, step["target"]) do
      nil ->
        {:failed, "no fixed fusion target set", state}

      target ->
        ingredient_ids = GiftPlans.ingredient_ids(target)

        cond do
          ingredient_ids == [] -> {:failed, "#{target.name} has no fixed recipe", state}
          owned?(target.id, ctx) -> {:skipped, "#{target.name} already owned", state}
          true -> gather_and_fuse(target, ingredient_ids, step["buy_missing"] != false, false, state, ctx)
        end
    end
  end

  defp gather_and_fuse(target, ingredient_ids, buy_missing?, bought?, state, ctx) do
    case missing(ingredient_ids, ctx) do
      [] ->
        fuse(target, ingredient_ids, state, ctx)

      missing_ids when buy_missing? ->
        case Ops.buy_missing_ids_from_shelf(missing_ids, ctx) do
          {:bought, _item} -> gather_and_fuse(target, ingredient_ids, buy_missing?, true, state, ctx)
          :none_available -> give_up(missing_ids, bought?, state)
        end

      missing_ids ->
        give_up(missing_ids, bought?, state)
    end
  end

  defp fuse(target, ingredient_ids, state, ctx) do
    fusion_target = %{gift_name: target.name, affinity: target.affinity}

    case Ops.perform_fusion(fusion_target, {:strict, ingredient_ids}, ctx) do
      :ok -> {:done, "fused #{target.name}", state}
      {:error, reason} -> {:failed, "fusion failed: #{inspect(reason)}", state}
    end
  end

  defp give_up(missing_ids, bought?, state) do
    names = Enum.map_join(missing_ids, ", ", &((state.gifts_by_id[&1] && state.gifts_by_id[&1].name) || &1))
    {if(bought?, do: :partial, else: :failed), "missing ingredients: #{names}", state}
  end

  defp missing(ingredient_ids, ctx), do: Enum.reject(ingredient_ids, &owned?(&1, ctx))

  defp owned?(gift_id, ctx), do: Map.has_key?(RunMemory.ego_gifts(ctx), gift_id)
end
