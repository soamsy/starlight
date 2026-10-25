defmodule StarlightBot.Automation.Shop.Actions.TieredFusion do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.EgoGifts
  alias StarlightBot.GiftPlans
  alias StarlightBot.GiftPlans.{Combos, FusionPlanner}

  @max_rounds 15

  def obtain(entry, step, state, ctx) do
    with {:ok, target} <- target(entry, state) do
      work(entry.fusion["routes"] || [], target, [], %{rounds: 0, misses: 0, retries: step["max_retries"]}, state, ctx)
    end
  end

  defp target(entry, state) do
    case state.gifts_by_name[entry.gift] do
      nil -> {:failed, "#{entry.gift} isn't a known gift", state}
      target -> {:ok, target}
    end
  end

  defp work(_routes, target, progress, %{rounds: rounds}, state, _ctx) when rounds >= @max_rounds,
    do: finish(progress, "stopped after #{@max_rounds} rounds without getting #{target.name}", state)

  defp work(routes, target, progress, round_counts, state, ctx) do
    if MapSet.member?(owned_names(ctx), target.name) do
      {:done, Enum.join(progress ++ ["got #{target.name}"], "; "), state}
    else
      fodder = fodder(state, ctx)
      counts = FusionPlanner.tier_counts(fodder)

      case FusionPlanner.next_fusion(routes, target.tier, counts, state.shop_type) do
        {:fuse, tier, combo} -> fuse(routes, target, tier, combo, fodder, progress, round_counts, state, ctx)
        nil -> buy(routes, target, counts, progress, round_counts, state, ctx)
      end
    end
  end

  defp fuse(routes, target, tier, combo, fodder, progress, %{misses: misses, retries: retries} = round_counts, state, ctx) do
    {:ok, picks} = FusionPlanner.pick_fodder(fodder, combo)
    label = "T#{tier} from #{Combos.combo_key(combo)}"

    fusion_target = %{
      gift_name: "#{label} toward #{target.name}",
      affinity: target.affinity,
      shop_type: state.shop_type,
      chance_comet?: Ops.chance_comet_ready?(state.plan, tier, ctx)
    }

    case Ops.perform_fusion(fusion_target, {:strict, Enum.map(picks, & &1.id)}, ctx) do
      :ok ->
        progress = progress ++ ["fused #{label}"]
        misses = if tier == target.tier and not MapSet.member?(owned_names(ctx), target.name), do: misses + 1, else: misses

        if is_integer(retries) and misses > retries,
          do: finish(progress, "missed #{target.name} #{misses} time(s), out of retries (#{retries})", state),
          else: work(routes, target, progress, %{round_counts | rounds: round_counts.rounds + 1, misses: misses}, state, ctx)

      {:error, reason} ->
        finish(progress, "fusing #{label} failed: #{inspect(reason)}", state)
    end
  end

  defp buy(routes, target, counts, progress, round_counts, state, ctx) do
    wanted = FusionPlanner.wanted_tiers(routes, target.tier, counts, state.shop_type)

    if MapSet.size(wanted) == 0 do
      finish(progress, "no reachable route for #{target.name} with what's owned", state)
    else
      with {:ok, items} <- Ops.shelf_items(ctx),
           {:bought, item} <- items |> candidates(wanted, state, ctx) |> Ops.buy_first_affordable(ctx) do
        work(routes, target, progress ++ ["bought #{item.gift_name}"], %{round_counts | rounds: round_counts.rounds + 1}, state, ctx)
      else
        :none_available -> finish(progress, "nothing affordable on the shelf fits a route", state)
        {:error, reason} -> finish(progress, "shelf scan failed: #{inspect(reason)}", state)
      end
    end
  end

  defp candidates(items, wanted, state, ctx) do
    owned = RunMemory.ego_gifts(ctx)

    items
    |> Enum.uniq_by(& &1.gift_id)
    |> Enum.reject(&((Map.has_key?(owned, &1.gift_id) and not EgoGifts.stackable?(&1.gift_name)) or GiftPlans.protected?(state.protected, state.gifts_by_id[&1.gift_id] || %{name: &1.gift_name, tier: nil})))
    |> Enum.filter(&(state.gifts_by_id[&1.gift_id] && state.gifts_by_id[&1.gift_id].tier in wanted))
    |> Enum.sort_by(&(-state.gifts_by_id[&1.gift_id].tier))
  end

  defp finish([], reason, state), do: {:failed, reason, state}
  defp finish(progress, reason, state), do: {:partial, Enum.join(progress, "; ") <> "; then " <> reason, state}

  defp fodder(state, ctx) do
    unfusable = RunMemory.unfusable_gifts(ctx)

    ctx
    |> RunMemory.ego_gifts()
    |> GiftPlans.fodder(state.protected, state.gifts_by_id)
    |> Enum.reject(&MapSet.member?(unfusable, &1.id))
  end

  defp owned_names(ctx), do: RunMemory.ego_gifts(ctx) |> Map.values() |> MapSet.new(& &1.name)
end
