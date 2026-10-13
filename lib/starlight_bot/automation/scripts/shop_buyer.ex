defmodule StarlightBot.Automation.Scripts.ShopBuyer do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RewardHelpers, RunMemory}
  alias StarlightBot.Ctx
  alias StarlightBot.EgoGifts
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{Capture, EgoGiftDetector, HookRegistry, Matcher, NumberScanner}

  @max_purchases 5
  @min_item_area_px 300
  @uptie_extend_px 50
  @uptie_2_hook :shop_sell_popup_uptie_2
  @uptie_1_hook :shop_sell_popup_uptie_1
  @purchase_result_timeout 5_000
  @normal_shelf_hooks [:shop_shelf_row_1, :shop_shelf_row_2]
  @super_shelf_hooks [:shop_super_shelf_row_1, :shop_super_shelf_row_2]

  @sell_open_hook :shop_sell
  @sell_popup_hook :shop_sell_popup
  @sell_inventory_hook :shop_sell_popup_inventory
  @sell_scroll_top_hook :shop_sell_popup_scroll_top
  @sell_scroll_bottom_hook :shop_sell_popup_scroll_bottom
  @sell_scroll_track_hook :shop_sell_popup_scroll_track
  @sell_scroll_hooks [@sell_scroll_top_hook, @sell_scroll_bottom_hook, @sell_scroll_track_hook]
  @sell_scroll_clicks 4
  @sell_scroll_settle_ms 400
  @max_sell_scroll_passes 20

  @affinity_hooks %{
    "burn" => :shop_affinity_burn,
    "bleed" => :shop_affinity_bleed,
    "tremor" => :shop_affinity_tremor,
    "rupture" => :shop_affinity_rupture,
    "sinking" => :shop_affinity_sinking,
    "poise" => :shop_affinity_poise,
    "charge" => :shop_affinity_charge,
    "slash" => :shop_affinity_slash,
    "pierce" => :shop_affinity_pierce,
    "blunt" => :shop_affinity_blunt
  }
  @fuse_open_hook :shop_fuse
  @fuse_popup_hook :shop_fuse_popup
  @fuse_select_keyword_hook :shop_fuse_popup_select_a_keyword
  @fuse_affinity_confirm_hook :shop_fuse_popup_affinity_popup_confirm
  @fuse_inventory_hook :shop_fuse_popup_inventory
  @fuse_owned_label_hook :shop_fuse_popup_ego_gifts_owned
  @fuse_scroll_top_hook :shop_fuse_popup_scroll_top
  @fuse_scroll_bottom_hook :shop_fuse_popup_scroll_bottom
  @fuse_scroll_track_hook :shop_fuse_popup_scroll_track
  @fuse_scroll_hooks [@fuse_scroll_top_hook, @fuse_scroll_bottom_hook, @fuse_scroll_track_hook]
  @fuse_item_1_empty_hook :shop_fuse_popup_item_1_empty
  @fuse_confirm_hook :shop_fuse_popup_confirm
  @fuse_confirm_confirm_hook :shop_fuse_popup_confirm_confirm
  @max_fuse_scroll_passes 20

  @item_points %{1 => 3, 2 => 6, 3 => 10, 4 => 15}
  @fusion_ranges %{1 => {9, 10}, 2 => {11, 16}, 3 => {17, 24}, 4 => {25, 45}}
  @super_fusion_ranges %{1 => {9, 9}, 2 => {10, 14}, 3 => {15, 21}, 4 => {22, 75}}

  def run(ctx) do
    detect_and_update_cost(ctx)
    Process.sleep(1000) # TODO: remove. this is unnecessary and just for debugging

    case check_inventory(ctx) do
      {:ok, _} ->
        case fetch_gift_strategy(ctx) do
          {:ok, gift_strategy} ->
            buy_pass(gift_strategy, @max_purchases, ctx)

          {:error, :no_gift_strategy} ->
            Ctx.log(ctx, :error, "shop buyer: no gift strategy in run memory — buying nothing")
            {:ok, :no_gift_strategy}
        end

      {:error, _} = err ->
        err
    end
  end

  def dry_run(ctx) do
    detect_and_update_cost(ctx)

    with {:ok, _} <- check_inventory(ctx),
         {:ok, gift_strategy} <- fetch_gift_strategy(ctx) do
      build_plan(buy_on_sight_index(gift_strategy), @max_purchases, ctx)
    end
  end

  defp fetch_gift_strategy(ctx) do
    case RunMemory.gift_strategy(ctx) do
      nil -> {:error, :no_gift_strategy}
      gift_strategy -> {:ok, gift_strategy}
    end
  end

  defp check_inventory(ctx) do
    case Engine.act([click(@sell_open_hook), await(@sell_popup_hook)], ctx) do
      {:ok, _} ->
        scan_visible_inventory(ctx)
        continue_scrolling_inventory(ctx, 0)
        log_inventory(ctx)
        close_sell_popup(ctx)

      {:error, _} = err ->
        err
    end
  end

  defp continue_scrolling_inventory(ctx, pass) when pass >= @max_sell_scroll_passes do
    Ctx.log(ctx, :error, "shop sell inventory scan: hit #{@max_sell_scroll_passes} scroll passes without reaching the bottom")
  end

  defp continue_scrolling_inventory(ctx, pass) do
    checks = Engine.check_all(@sell_scroll_hooks)
    scrollable? = checks[@sell_scroll_top_hook] or checks[@sell_scroll_bottom_hook] or checks[@sell_scroll_track_hook]

    cond do
      not scrollable? ->
        :ok

      checks[@sell_scroll_bottom_hook] ->
        :ok

      true ->
        Engine.act(
          [move_to(@sell_inventory_hook), scroll_down(@sell_scroll_clicks), sleep(@sell_scroll_settle_ms)],
          ctx
        )

        scan_visible_inventory(ctx)
        continue_scrolling_inventory(ctx, pass + 1)
    end
  end

  defp scan_visible_inventory(ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, hook} <- find_hook(@sell_inventory_hook, ctx, "shop sell inventory scan") do
      gifts = detect_inventory_gifts(frame, hook.scan_region || hook.region, ctx)
      Enum.each(gifts, &record_inventory_item(&1, ctx))
      assign_uptie_level(frame, gifts, @uptie_2_hook, 2, ctx)
      assign_uptie_level(frame, gifts, @uptie_1_hook, 1, ctx)
    else
      {:error, reason} -> Ctx.log(ctx, :error, "shop sell inventory scan: #{inspect(reason)}")
    end
  end

  defp find_hook(hook_name, ctx, log_prefix) do
    case HookRegistry.find(hook_name) do
      {:ok, %{region: nil, scan_region: nil}} ->
        Ctx.log(ctx, :error, "#{log_prefix}: #{hook_name} hook has no region configured")
        {:error, :no_region}

      {:ok, hook} ->
        {:ok, hook}

      {:error, :not_found} ->
        Ctx.log(ctx, :error, "#{log_prefix}: #{hook_name} hook not found")
        {:error, :not_found}
    end
  end

  defp detect_inventory_gifts(frame, region, ctx) do
    case EgoGiftDetector.detect(frame.mat, region) do
      {:ok, results} ->
        results
        |> Enum.filter(&item_large_enough?/1)
        |> Enum.reject(&(&1.gift_id == nil))

      {:error, reason} ->
        Ctx.log(ctx, :error, "shop sell inventory scan: classify failed: #{inspect(reason)}")
        []
    end
  end

  defp record_inventory_item(%{gift_id: gift_id, gift_name: gift_name}, ctx) do
    RunMemory.add_ego_gift(ctx, gift_id, gift_name)
  end

  defp assign_uptie_level(frame, gifts, hook_name, uptie, ctx) do
    frame
    |> Matcher.find_all(hook_name)
    |> Enum.each(&apply_uptie_badge(&1, gifts, uptie, ctx))
  end

  defp apply_uptie_badge(badge_rect, gifts, uptie, ctx) do
    case best_gift_match(extend_rect(badge_rect), gifts) do
      {%{gift_id: gift_id, gift_name: gift_name}, _area} ->
        RunMemory.set_ego_gift_uptie(ctx, gift_id, uptie)
        Ctx.log(ctx, :info, "shop sell inventory scan: #{gift_name} — uptie #{uptie}")

      nil ->
        :ok
    end
  end

  defp extend_rect({x, y, w, h}), do: {x - @uptie_extend_px, y, w + @uptie_extend_px, h + @uptie_extend_px}

  defp best_gift_match(extended_rect, gifts) do
    gifts
    |> Enum.map(&{&1, rect_intersection_area(extended_rect, {&1.x, &1.y, &1.w, &1.h})})
    |> Enum.filter(fn {_gift, area} -> area > 0 end)
    |> Enum.max_by(fn {_gift, area} -> area end, fn -> nil end)
  end

  defp rect_intersection_area({ax, ay, aw, ah}, {bx, by, bw, bh}) do
    x_overlap = max(0, min(ax + aw, bx + bw) - max(ax, bx))
    y_overlap = max(0, min(ay + ah, by + bh) - max(ay, by))
    x_overlap * y_overlap
  end

  defp log_inventory(ctx) do
    names = RunMemory.ego_gifts(ctx) |> Map.values() |> Enum.map(& &1.name) |> Enum.sort()
    Ctx.log(ctx, :ok, "shop sell inventory: #{length(names)} item(s) owned: #{Enum.join(names, ", ")}")
  end

  defp close_sell_popup(ctx) do
    Engine.act([retry_until(not_hook(@sell_popup_hook), [key(:esc)], every: 400, tries: 5)], ctx)
  end

  defp buy_on_sight_index(gift_strategy) do
    gift_strategy
    |> Map.get("buy_on_sight", [])
    |> Map.new(fn entry -> {entry["gift"], entry["weight"] || 0} end)
  end

  defp buy_pass(gift_strategy, remaining, ctx) do
    case scan_and_buy(buy_on_sight_index(gift_strategy), remaining, ctx) do
      {:ok, remaining_after} ->
        maybe_refresh_and_continue(gift_strategy, remaining_after, ctx)

      {:stop, remaining_after} ->
        finish_shopping(gift_strategy, remaining_after, ctx)

      {:error, _} = err ->
        err
    end
  end

  defp maybe_refresh_and_continue(gift_strategy, remaining, ctx) do
    cond do
      remaining == 0 ->
        finish_shopping(gift_strategy, remaining, ctx)

      Engine.check(:shop_refresh_disabled) ->
        Ctx.log(ctx, :info, "shop buyer: refresh disabled, leaving with #{@max_purchases - remaining} bought")
        finish_shopping(gift_strategy, remaining, ctx)

      RunMemory.shop_refreshes_used(ctx) >= max_normal_refreshes(gift_strategy) ->
        Ctx.log(ctx, :info, "shop buyer: hit configured refresh limit, leaving with #{@max_purchases - remaining} bought")
        finish_shopping(gift_strategy, remaining, ctx)

      true ->
        case Engine.run_action(:shop, :refresh_shelf, ctx) do
          {:ok, _} ->
            RunMemory.increment_shop_refreshes(ctx)
            detect_and_update_cost(ctx)
            buy_pass(gift_strategy, remaining, ctx)

          {:error, _} = err ->
            err
        end
    end
  end

  defp finish_shopping(gift_strategy, remaining, ctx) do
    attempt_fusion(gift_strategy, remaining, ctx)
    {:ok, remaining}
  end

  defp max_normal_refreshes(gift_strategy) do
    gift_strategy
    |> Map.get("refresh_policy", %{})
    |> Map.get("max_normal_refreshes", 0)
  end

  defp attempt_fusion(gift_strategy, remaining, ctx) do
    case pick_fusion_target(gift_strategy, ctx) do
      nil -> :ok
      target -> run_fusion(target, gift_strategy, remaining, ctx)
    end
  end

  defp pick_fusion_target(gift_strategy, ctx) do
    gifts_by_name = Map.new(EgoGifts.list_gifts(), &{&1.name, &1})
    owned = RunMemory.ego_gifts(ctx)

    gift_strategy
    |> Map.get("fusion_targets", [])
    |> Enum.map(&resolve_fusion_target(&1, gifts_by_name))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&Map.has_key?(owned, &1.gift_id))
    |> Enum.sort_by(& &1.weight, :desc)
    |> List.first()
  end

  defp resolve_fusion_target(entry, gifts_by_name) do
    with gift_name when is_binary(gift_name) <- entry["gift"],
         %{tier: tier} = gift when is_integer(tier) <- Map.get(gifts_by_name, gift_name) do
      %{
        gift_name: gift_name,
        gift_id: gift.id,
        affinity: gift.affinity,
        weight: entry["weight"] || 0,
        ingredient_source: entry["ingredient_source"] || "buy_if_short",
        recipe: fusion_recipe(gift)
      }
    else
      _ -> nil
    end
  end

  defp fusion_recipe(%{ingredients: ingredients}) when is_binary(ingredients) and ingredients != "" do
    {:strict, String.split(ingredients, ",", trim: true)}
  end

  defp fusion_recipe(%{tier: tier}), do: {:tiered, tier}

  defp run_fusion(target, gift_strategy, remaining, ctx) do
    keep = MapSet.new(Map.get(gift_strategy, "keep", []))
    buy_on_sight = buy_on_sight_index(gift_strategy)
    max_refreshes = max_normal_refreshes(gift_strategy)

    case ensure_ingredients(target, keep, buy_on_sight, max_refreshes, remaining, ctx) do
      {:ok, _remaining_after, click_plan} ->
        perform_fusion(target, click_plan, ctx)

      {:give_up, _remaining_after} ->
        Ctx.log(ctx, :info, "shop fuse: couldn't gather ingredients for #{target.gift_name} — skipping")
    end
  end

  defp ensure_ingredients(target, keep, buy_on_sight, max_refreshes, remaining, ctx) do
    case target.recipe do
      {:strict, ingredient_ids} ->
        ensure_strict_ingredients(target, ingredient_ids, keep, buy_on_sight, max_refreshes, remaining, ctx)

      {:tiered, tier} ->
        ensure_tiered_ingredients(target, tier, keep, buy_on_sight, max_refreshes, remaining, ctx)
    end
  end

  defp ensure_strict_ingredients(target, ingredient_ids, keep, buy_on_sight, max_refreshes, remaining, ctx) do
    case missing_ingredient_ids(ingredient_ids, keep, ctx) do
      [] ->
        {:ok, remaining, {:strict, ingredient_ids}}

      _missing when target.ingredient_source == "junk_only" ->
        {:give_up, remaining}

      missing when remaining > 0 ->
        case buy_missing_ids_from_shelf(missing, ctx) do
          {:bought, _item} ->
            ensure_strict_ingredients(target, ingredient_ids, keep, buy_on_sight, max_refreshes, remaining - 1, ctx)

          :none_available ->
            try_refresh_and_retry(max_refreshes, buy_on_sight, remaining, ctx, fn remaining_after ->
              ensure_strict_ingredients(target, ingredient_ids, keep, buy_on_sight, max_refreshes, remaining_after, ctx)
            end)
        end

      _missing ->
        try_refresh_and_retry(max_refreshes, buy_on_sight, remaining, ctx, fn remaining_after ->
          ensure_strict_ingredients(target, ingredient_ids, keep, buy_on_sight, max_refreshes, remaining_after, ctx)
        end)
    end
  end

  defp ensure_tiered_ingredients(target, tier, keep, buy_on_sight, max_refreshes, remaining, ctx) do
    case pick_best_tiered_combo(tier, keep, ctx) do
      nil ->
        {:give_up, remaining}

      %{missing: missing, needed: needed} when map_size(missing) == 0 ->
        {:ok, remaining, {:tiered, needed}}

      _combo when target.ingredient_source == "junk_only" ->
        {:give_up, remaining}

      %{missing: missing} when remaining > 0 ->
        case buy_missing_tier_from_shelf(missing, ctx) do
          {:bought, _item} ->
            ensure_tiered_ingredients(target, tier, keep, buy_on_sight, max_refreshes, remaining - 1, ctx)

          :none_available ->
            try_refresh_and_retry(max_refreshes, buy_on_sight, remaining, ctx, fn remaining_after ->
              ensure_tiered_ingredients(target, tier, keep, buy_on_sight, max_refreshes, remaining_after, ctx)
            end)
        end

      _combo ->
        try_refresh_and_retry(max_refreshes, buy_on_sight, remaining, ctx, fn remaining_after ->
          ensure_tiered_ingredients(target, tier, keep, buy_on_sight, max_refreshes, remaining_after, ctx)
        end)
    end
  end

  defp pick_best_tiered_combo(target_tier, keep, ctx) do
    {low, high} = Map.fetch!(fusion_range_table(), target_tier)
    owned_counts = owned_tier_counts(keep, ctx)

    for(a <- 1..4, b <- a..4, c <- b..4, do: [a, b, c])
    |> Enum.map(&score_tiered_combo(&1, owned_counts))
    |> Enum.filter(&(&1.total in low..high and Map.get(&1.missing, 4, 0) == 0))
    |> Enum.sort_by(&{Enum.max(&1.combo), &1.missing_cost, &1.total})
    |> List.first()
  end

  defp fusion_range_table do
    if Engine.check(:shop_super), do: @super_fusion_ranges, else: @fusion_ranges
  end

  defp score_tiered_combo(combo, owned_counts) do
    needed = Enum.frequencies(combo)

    missing =
      Enum.reduce(needed, %{}, fn {tier, count}, acc ->
        deficit = max(0, count - Map.get(owned_counts, tier, 0))
        if deficit > 0, do: Map.put(acc, tier, deficit), else: acc
      end)

    %{
      combo: combo,
      needed: needed,
      missing: missing,
      missing_cost: Enum.reduce(missing, 0, fn {tier, count}, acc -> acc + count * @item_points[tier] end),
      total: Enum.reduce(combo, 0, &(@item_points[&1] + &2))
    }
  end

  defp owned_tier_counts(keep, ctx) do
    gifts_by_id = Map.new(EgoGifts.list_gifts(), &{&1.id, &1})

    RunMemory.ego_gifts(ctx)
    |> Enum.reject(fn {_id, %{name: name}} -> MapSet.member?(keep, name) end)
    |> Enum.reduce(%{}, fn {id, _info}, acc ->
      case Map.get(gifts_by_id, id) do
        %{tier: t} when is_integer(t) -> Map.update(acc, t, 1, &(&1 + 1))
        _ -> acc
      end
    end)
  end

  defp try_refresh_and_retry(max_refreshes, buy_on_sight, remaining, ctx, retry_fun) do
    if RunMemory.shop_refreshes_used(ctx) < max_refreshes and not Engine.check(:shop_refresh_disabled) do
      case Engine.run_action(:shop, :refresh_shelf, ctx) do
        {:ok, _} ->
          RunMemory.increment_shop_refreshes(ctx)
          detect_and_update_cost(ctx)
          retry_fun.(run_buy_on_sight_once(buy_on_sight, remaining, ctx))

        {:error, _} ->
          {:give_up, remaining}
      end
    else
      {:give_up, remaining}
    end
  end

  defp run_buy_on_sight_once(buy_on_sight, remaining, ctx) do
    case scan_and_buy(buy_on_sight, remaining, ctx) do
      {:ok, remaining_after} -> remaining_after
      {:stop, remaining_after} -> remaining_after
      {:error, _} -> remaining
    end
  end

  defp missing_ingredient_ids(ingredient_ids, keep, ctx) do
    owned = RunMemory.ego_gifts(ctx)

    Enum.filter(ingredient_ids, fn id ->
      case Map.fetch(owned, id) do
        {:ok, %{name: name}} -> MapSet.member?(keep, name)
        :error -> true
      end
    end)
  end

  defp buy_missing_ids_from_shelf(missing_ids, ctx) do
    missing_set = MapSet.new(missing_ids)

    case Capture.grab_frame() do
      {:ok, frame} ->
        shelf_hooks()
        |> Enum.flat_map(&detect_fuse_id_shelf_row(frame, &1, missing_set, ctx))
        |> buy_first_affordable(ctx)

      {:error, reason} ->
        Ctx.log(ctx, :error, "shop fuse: shelf scan failed: #{inspect(reason)}")
        :none_available
    end
  end

  defp detect_fuse_id_shelf_row(frame, hook_name, missing_set, ctx) do
    case HookRegistry.find(hook_name) do
      {:ok, %{region: nil, scan_region: nil}} -> []
      {:ok, hook} -> detect_fuse_id_candidates(frame, hook.scan_region || hook.region, missing_set, ctx)
      {:error, :not_found} -> []
    end
  end

  defp detect_fuse_id_candidates(frame, region, missing_set, ctx) do
    case EgoGiftDetector.detect(frame.mat, region) do
      {:ok, results} ->
        results
        |> Enum.filter(&item_large_enough?/1)
        |> Enum.filter(&MapSet.member?(missing_set, &1[:gift_id]))

      {:error, reason} ->
        Ctx.log(ctx, :error, "shop fuse: shelf classify failed: #{inspect(reason)}")
        []
    end
  end

  defp buy_missing_tier_from_shelf(missing_tiers, ctx) do
    gifts_by_id = Map.new(EgoGifts.list_gifts(), &{&1.id, &1})

    case Capture.grab_frame() do
      {:ok, frame} ->
        shelf_hooks()
        |> Enum.flat_map(&detect_tier_shelf_row(frame, &1, missing_tiers, gifts_by_id, ctx))
        |> buy_first_affordable(ctx)

      {:error, reason} ->
        Ctx.log(ctx, :error, "shop fuse: shelf scan failed: #{inspect(reason)}")
        :none_available
    end
  end

  defp detect_tier_shelf_row(frame, hook_name, missing_tiers, gifts_by_id, ctx) do
    case HookRegistry.find(hook_name) do
      {:ok, %{region: nil, scan_region: nil}} -> []
      {:ok, hook} -> detect_tier_candidates(frame, hook.scan_region || hook.region, missing_tiers, gifts_by_id, ctx)
      {:error, :not_found} -> []
    end
  end

  defp detect_tier_candidates(frame, region, missing_tiers, gifts_by_id, ctx) do
    case EgoGiftDetector.detect(frame.mat, region) do
      {:ok, results} ->
        results
        |> Enum.filter(&item_large_enough?/1)
        |> Enum.filter(&tier_still_needed?(&1, missing_tiers, gifts_by_id))

      {:error, reason} ->
        Ctx.log(ctx, :error, "shop fuse: shelf classify failed: #{inspect(reason)}")
        []
    end
  end

  defp tier_still_needed?(%{gift_id: gift_id}, missing_tiers, gifts_by_id) do
    case Map.get(gifts_by_id, gift_id) do
      %{tier: tier} -> Map.has_key?(missing_tiers, tier)
      _ -> false
    end
  end

  defp buy_first_affordable([], _ctx), do: :none_available

  defp buy_first_affordable([item | rest], ctx) do
    cost = EgoGifts.buying_cost_for(item.gift_id) || 0

    if cost <= (RunMemory.cost(ctx) || 0) do
      case buy_item(item, ctx) do
        {:ok, :bought} -> {:bought, item}
        _ -> :none_available
      end
    else
      buy_first_affordable(rest, ctx)
    end
  end

  defp perform_fusion(target, click_plan, ctx) do
    with {:ok, _} <- Engine.act([click(@fuse_open_hook), await(@fuse_popup_hook)], ctx),
         :ok <- select_affinity(target, ctx),
         {:ok, consumed_ids} <- select_fuse_ingredients(click_plan, ctx),
         :ok <- confirm_fuse(ctx) do
      Enum.each(consumed_ids, &RunMemory.remove_ego_gift(ctx, &1))
      Engine.act([RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step()], ctx)
    else
      {:error, reason} ->
        Ctx.log(ctx, :error, "shop fuse: #{target.gift_name} — #{inspect(reason)}")
        Engine.act([key(:esc)], ctx)
    end
  end

  defp select_affinity(target, ctx) do
    if Engine.check(@fuse_select_keyword_hook) do
      case Map.fetch(@affinity_hooks, target.affinity) do
        {:ok, affinity_hook} ->
          case Engine.act(
                 [click(@fuse_select_keyword_hook), click(affinity_hook), click(@fuse_affinity_confirm_hook)],
                 ctx
               ) do
            {:ok, _} -> :ok
            {:error, _} = err -> err
          end

        :error ->
          {:error, {:unknown_affinity, target.affinity}}
      end
    else
      :ok
    end
  end

  defp select_fuse_ingredients(click_plan, ctx) do
    state =
      case click_plan do
        {:strict, ingredient_ids} -> {:strict, MapSet.new(ingredient_ids), MapSet.new()}
        {:tiered, needed} -> {:tiered, needed, MapSet.new()}
      end

    select_fuse_pass(state, ctx, 0)
  end

  defp select_fuse_pass(_state, _ctx, pass) when pass >= @max_fuse_scroll_passes do
    {:error, :fuse_scroll_limit}
  end

  defp select_fuse_pass(state, ctx, pass) do
    with {:ok, state_after} <- scan_and_click_fuse_items(state, ctx) do
      cond do
        fuse_selection_done?(state_after) ->
          {:ok, clicked_ids(state_after)}

        not fuse_scrollable?() or Engine.check(@fuse_scroll_bottom_hook) ->
          {:error, {:missing_ingredients, state_after}}

        true ->
          Engine.act(
            [move_to(@fuse_inventory_hook), scroll_down(@sell_scroll_clicks), sleep(@sell_scroll_settle_ms)],
            ctx
          )

          select_fuse_pass(state_after, ctx, pass + 1)
      end
    end
  end

  defp fuse_selection_done?({:strict, needed, clicked}), do: MapSet.subset?(needed, clicked)
  defp fuse_selection_done?({:tiered, needed, _clicked}), do: needed |> Map.values() |> Enum.all?(&(&1 == 0))

  defp clicked_ids({_kind, _needed, clicked}), do: MapSet.to_list(clicked)

  defp fuse_scrollable? do
    @fuse_scroll_hooks
    |> Engine.check_all()
    |> Map.values()
    |> Enum.any?()
  end

  defp scan_and_click_fuse_items(state, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, region} <- fuse_inventory_region(frame, ctx) do
      gifts = detect_inventory_gifts(frame, region, ctx)
      {:ok, click_matching_fuse_items(state, gifts, ctx)}
    end
  end

  defp click_item_rect(item, ctx) do
    RewardHelpers.click_rect({round(item.x), round(item.y), round(item.w), round(item.h)}, ctx)
  end

  defp click_matching_fuse_items({:strict, needed, clicked}, gifts, ctx) do
    clicked_after =
      Enum.reduce(gifts, clicked, fn item, acc ->
        if MapSet.member?(needed, item.gift_id) and not MapSet.member?(acc, item.gift_id) do
          click_item_rect(item, ctx)
          MapSet.put(acc, item.gift_id)
        else
          acc
        end
      end)

    {:strict, needed, clicked_after}
  end

  defp click_matching_fuse_items({:tiered, needed, clicked}, gifts, ctx) do
    gifts_by_id = Map.new(EgoGifts.list_gifts(), &{&1.id, &1})

    {needed_after, clicked_after} =
      Enum.reduce(gifts, {needed, clicked}, fn item, {needed_acc, clicked_acc} ->
        case Map.get(gifts_by_id, item.gift_id) do
          %{tier: tier} when tier != nil ->
            if Map.get(needed_acc, tier, 0) > 0 and not MapSet.member?(clicked_acc, item.gift_id) do
              click_item_rect(item, ctx)
              {Map.update!(needed_acc, tier, &(&1 - 1)), MapSet.put(clicked_acc, item.gift_id)}
            else
              {needed_acc, clicked_acc}
            end

          _ ->
            {needed_acc, clicked_acc}
        end
      end)

    {:tiered, needed_after, clicked_after}
  end

  defp fuse_inventory_region(frame, ctx) do
    with {:ok, hook} <- find_hook(@fuse_inventory_hook, ctx, "shop fuse ingredient scan") do
      {:ok, crop_below_owned_label(frame, hook.scan_region || hook.region)}
    end
  end

  defp crop_below_owned_label(frame, {x, y, w, h}) do
    case Matcher.find(frame, @fuse_owned_label_hook) do
      {:ok, {_lx, ly, _lw, lh}} -> {x, ly + lh, w, y + h - (ly + lh)}
      :not_found -> {x, y, w, h}
    end
  end

  defp confirm_fuse(ctx) do
    if Engine.check(@fuse_item_1_empty_hook) do
      {:error, :no_ingredients_selected}
    else
      case Engine.act([click(@fuse_confirm_hook), await(@fuse_confirm_confirm_hook), click(@fuse_confirm_confirm_hook)], ctx) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp scan_and_buy(buy_on_sight, remaining, ctx) do
    case build_plan(buy_on_sight, remaining, ctx) do
      {:ok, plan} ->
        Ctx.log(
          ctx,
          :info,
          "shop buyer: #{length(plan.candidates)} buy-on-sight item(s) available — buying #{length(plan.selected)} " <>
            "for total weight #{plan.total_weight} within budget #{plan.budget}"
        )

        buy_each(plan.selected, remaining, ctx)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_plan(buy_on_sight, remaining, ctx) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        candidates = matching_candidates(frame, buy_on_sight, ctx)
        budget = RunMemory.cost(ctx) || 0
        selected = best_purchase_set(candidates, budget, remaining)
        selected_ids = MapSet.new(selected, & &1.gift_id)

        plan = %{
          budget: budget,
          max_purchases: remaining,
          candidates: candidates,
          selected: selected,
          skipped: Enum.reject(candidates, &(&1.gift_id in selected_ids)),
          total_cost: Enum.reduce(selected, 0, &(&1.cost + &2)),
          total_weight: total_weight(selected)
        }

        RunMemory.put_shop_plan(ctx, plan)
        {:ok, plan}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp total_weight(items), do: Enum.reduce(items, 0, &(&1.weight + &2))

  defp best_purchase_set(candidates, budget, max_count) do
    candidates
    |> Enum.reduce(%{{0, 0} => {0, []}}, fn item, states ->
      Enum.reduce(states, states, fn {{spent, count}, {weight, items}}, acc ->
        new_spent = spent + item.cost
        new_count = count + 1
        new_weight = weight + item.weight

        if new_spent <= budget and new_count <= max_count do
          Map.update(acc, {new_spent, new_count}, {new_weight, [item | items]}, fn {existing_weight, _} = existing ->
            if new_weight > existing_weight, do: {new_weight, [item | items]}, else: existing
          end)
        else
          acc
        end
      end)
    end)
    |> Map.values()
    |> Enum.max_by(fn {weight, _items} -> weight end, fn -> {0, []} end)
    |> elem(1)
  end

  defp buy_each(_candidates, 0, _ctx), do: {:ok, 0}
  defp buy_each([], remaining, _ctx), do: {:ok, remaining}

  defp buy_each([item | rest], remaining, ctx) do
    case buy_item(item, ctx) do
      {:ok, :bought} -> buy_each(rest, remaining - 1, ctx)
      {:ok, :insufficient_funds} -> {:stop, remaining}
      {:error, _} = err -> err
    end
  end

  defp buy_item(%{gift_name: gift_name} = item, ctx) do
    Ctx.log(ctx, :info, "shop buyer: buying #{gift_name}")

    with {:ok, _} <- RewardHelpers.click_rect({round(item.x), round(item.y), round(item.w), round(item.h)}, ctx),
         {:ok, outcome} <- await_purchase_result(ctx) do
      finish_purchase(outcome, gift_name, ctx)
    end
  end

  defp finish_purchase(:confirm, gift_name, ctx) do
    with {:ok, _} <- Engine.act([click(:shop_purchase_popup_confirm)], ctx),
         {:ok, _} <-
           Engine.act([RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step()], ctx) do
      Ctx.log(ctx, :ok, "shop buyer: bought #{gift_name}")
      {:ok, :bought}
    end
  end

  defp finish_purchase(:insufficient_funds, gift_name, ctx) do
    Ctx.log(ctx, :info, "shop buyer: not enough cost for #{gift_name} — backing out and stopping")

    case Engine.act([key(:esc)], ctx) do
      {:ok, _} -> {:ok, :insufficient_funds}
      {:error, _} = err -> err
    end
  end

  defp await_purchase_result(ctx) do
    steps = [await_any([:shop_purchase_popup_confirm, :shop_purchase_pop_gift_info], timeout: @purchase_result_timeout)]

    case Engine.act(steps, ctx) do
      {:ok, frame} ->
        if Runner.hook_matches?(frame, :shop_purchase_pop_gift_info) do
          {:ok, :insufficient_funds}
        else
          {:ok, :confirm}
        end

      {:error, _} = err ->
        err
    end
  end

  defp matching_candidates(frame, buy_on_sight, ctx) do
    shelf_hooks()
    |> Enum.flat_map(&detect_row(frame, &1, buy_on_sight, ctx))
  end

  defp shelf_hooks do
    if Engine.check(:shop_super), do: @super_shelf_hooks, else: @normal_shelf_hooks
  end

  defp detect_row(frame, hook_name, buy_on_sight, ctx) do
    case HookRegistry.find(hook_name) do
      {:ok, %{region: nil, scan_region: nil}} ->
        Ctx.log(ctx, :error, "shop buyer: #{hook_name} hook has no region configured")
        []

      {:ok, hook} ->
        detect_candidates(frame, hook.scan_region || hook.region, buy_on_sight, ctx)

      {:error, :not_found} ->
        Ctx.log(ctx, :error, "shop buyer: #{hook_name} hook not found")
        []
    end
  end

  defp detect_candidates(frame, region, buy_on_sight, ctx) do
    case EgoGiftDetector.detect(frame.mat, region) do
      {:ok, results} ->
        results
        |> Enum.filter(&item_large_enough?/1)
        |> Enum.map(&buy_target(&1, buy_on_sight, ctx))
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Ctx.log(ctx, :error, "shop buyer: shelf classify failed: #{inspect(reason)}")
        []
    end
  end

  defp item_large_enough?(%{w: w, h: h}), do: w * h >= @min_item_area_px

  defp buy_target(%{gift_id: nil}, _buy_on_sight, _ctx), do: nil

  defp buy_target(%{gift_id: gift_id, gift_name: gift_name} = item, buy_on_sight, ctx) do
    already_owned? = Map.has_key?(RunMemory.ego_gifts(ctx), gift_id)
    weight = Map.get(buy_on_sight, gift_name)

    cond do
      already_owned? ->
        Ctx.log(ctx, :info, "shop buyer: #{gift_name} — skip (already owned)")
        nil

      is_nil(weight) ->
        Ctx.log(ctx, :info, "shop buyer: #{gift_name} — skip (not buy-on-sight)")
        nil

      true ->
        cost = EgoGifts.buying_cost_for(gift_id) || 0
        Ctx.log(ctx, :info, "shop buyer: #{gift_name} — buy-on-sight (weight #{weight}, cost #{cost})")
        Map.merge(item, %{weight: weight, cost: cost})
    end
  end

  defp detect_and_update_cost(ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, cost} <- NumberScanner.read(frame) do
      Ctx.log(ctx, :info, "cost: read #{cost}")
      RunMemory.put_cost(ctx, cost)
    else
      other ->
        Ctx.log(ctx, :error, "cost: read failed (#{inspect(other)})")
        :ok
    end
  end

end
