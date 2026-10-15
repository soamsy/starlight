defmodule StarlightBot.Automation.Shop.Ops do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RewardHelpers, RunMemory}
  alias StarlightBot.Ctx
  alias StarlightBot.EgoGifts
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{Capture, EgoGiftDetector, HookRegistry, Matcher, NumberScanner}

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
  @sell_popup %{
    name: "sell",
    inventory: @sell_inventory_hook,
    top: @sell_scroll_top_hook,
    bottom: @sell_scroll_bottom_hook,
    track: @sell_scroll_track_hook
  }
  @uptie_popup %{
    name: "uptie",
    inventory: :shop_uptie_popup_inventory,
    top: :shop_uptie_popup_scroll_top,
    bottom: :shop_uptie_popup_scroll_bottom,
    track: :shop_uptie_popup_scroll_track
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

  def shop_type, do: if(Engine.check(:shop_super), do: :super, else: :normal)

  def recover_to_shop(ctx) do
    Engine.act([retry_until(@sell_open_hook, [key(:esc)], every: 400, tries: 5)], ctx)
  end

  def check_inventory(ctx) do
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

  def refresh_shelf(ctx) do
    if Engine.check(:shop_refresh_disabled) do
      {:error, :refresh_disabled}
    else
      Engine.run_action(:shop, :refresh_shelf, ctx)
    end
  end

  def shelf_items(ctx) do
    case Capture.grab_frame() do
      {:ok, frame} -> {:ok, Enum.flat_map(shelf_hooks(), &detect_row(frame, &1, ctx))}
      {:error, _} = err -> err
    end
  end

  defp shelf_hooks do
    if Engine.check(:shop_super), do: @super_shelf_hooks, else: @normal_shelf_hooks
  end

  defp detect_row(frame, hook_name, ctx) do
    case find_hook(hook_name, ctx, "shop shelf scan") do
      {:ok, hook} -> detect_shelf_items(frame, hook.scan_region || hook.region, ctx)
      {:error, _} -> []
    end
  end

  defp detect_shelf_items(frame, region, ctx) do
    case EgoGiftDetector.detect(frame.mat, region) do
      {:ok, results} ->
        results
        |> Enum.filter(&item_large_enough?/1)
        |> Enum.reject(&(&1.gift_id == nil))

      {:error, reason} ->
        Ctx.log(ctx, :error, "shop shelf scan: classify failed: #{inspect(reason)}")
        []
    end
  end

  defp item_large_enough?(%{w: w, h: h}), do: w * h >= @min_item_area_px

  def buy_missing_ids_from_shelf(missing_ids, ctx) do
    missing_set = MapSet.new(missing_ids)

    case shelf_items(ctx) do
      {:ok, items} ->
        items
        |> Enum.filter(&MapSet.member?(missing_set, &1.gift_id))
        |> buy_first_affordable(ctx)

      {:error, reason} ->
        Ctx.log(ctx, :error, "shop fuse: shelf scan failed: #{inspect(reason)}")
        :none_available
    end
  end

  def buy_first_affordable([], _ctx), do: :none_available

  def buy_first_affordable([item | rest], ctx) do
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

  def buy_item(%{gift_name: gift_name} = item, ctx) do
    Ctx.log(ctx, :info, "shop: buying #{gift_name}")

    with {:ok, _} <- RewardHelpers.click_rect({round(item.x), round(item.y), round(item.w), round(item.h)}, ctx),
         {:ok, outcome} <- await_purchase_result(ctx) do
      finish_purchase(outcome, gift_name, ctx)
    end
  end

  defp finish_purchase(:confirm, gift_name, ctx) do
    with {:ok, _} <- Engine.act([click(:shop_purchase_popup_confirm)], ctx),
         {:ok, _} <-
           Engine.act([RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step()], ctx) do
      Ctx.log(ctx, :ok, "shop: bought #{gift_name}")
      {:ok, :bought}
    end
  end

  defp finish_purchase(:insufficient_funds, gift_name, ctx) do
    Ctx.log(ctx, :info, "shop: not enough cost for #{gift_name} — backing out")

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

  def perform_fusion(target, click_plan, ctx) do
    with {:ok, _} <- Engine.act([click(@fuse_open_hook), await(@fuse_popup_hook)], ctx),
         :ok <- select_affinity(target, ctx),
         {:ok, consumed_ids} <- select_fuse_ingredients(click_plan, ctx),
         :ok <- confirm_fuse(ctx),
         Enum.each(consumed_ids, &RunMemory.remove_ego_gift(ctx, &1)),
         {:ok, _} <-
           Engine.act([RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step()], ctx) do
      :ok
    else
      {:error, reason} = err ->
        Ctx.log(ctx, :error, "shop fuse: #{target.gift_name} — #{inspect(reason)}")
        recover_to_shop(ctx)
        err
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
    {:strict, ingredient_ids} = click_plan
    select_fuse_pass({:strict, MapSet.new(ingredient_ids), MapSet.new()}, ctx, 0)
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

  def sell_gift(gift_id, ctx) do
    with {:ok, _} <- Engine.act([click(@sell_open_hook), await(@sell_popup_hook)], ctx),
         :ok <- find_and_click_gift(@sell_popup, gift_id, ctx, 0),
         {:ok, _} <-
           Engine.act(
             [click(:shop_sell_popup_confirm), await(:shop_sell_popup_confirm_confirm), click(:shop_sell_popup_confirm_confirm)],
             ctx
           ) do
      RunMemory.remove_ego_gift(ctx, gift_id)
      close_sell_popup(ctx)
      :ok
    else
      {:error, reason} = err ->
        Ctx.log(ctx, :error, "shop sell: #{gift_id} — #{inspect(reason)}")
        recover_to_shop(ctx)
        err
    end
  end

  def select_uptie_gift(gift_id, ctx) do
    with {:ok, _} <- Engine.act([click(:shop_uptie), await(:shop_uptie_popup)], ctx),
         :ok <- find_and_click_gift(@uptie_popup, gift_id, ctx, 0) do
      :ok
    else
      {:error, reason} = err ->
        Ctx.log(ctx, :error, "shop uptie: #{gift_id} — #{inspect(reason)}")
        err
    end
  end

  def keyword_refresh(affinity, ctx) do
    with {:ok, affinity_hook} <- affinity_hook(affinity),
         false <- Engine.check(:shop_keyword_refresh_disabled),
         {:ok, _} <-
           Engine.act(
             [
               click(:shop_keyword_refresh),
               await(:shop_keyword_refresh_popup),
               click(affinity_hook),
               click(:shop_keyword_refresh_popup_confirm),
               await(not_hook(:shop_keyword_refresh_popup))
             ],
             ctx
           ) do
      :ok
    else
      true -> {:error, :keyword_refresh_disabled}
      {:error, _} = err -> err
    end
  end

  defp affinity_hook(affinity) do
    case Map.fetch(@affinity_hooks, affinity) do
      {:ok, hook} -> {:ok, hook}
      :error -> {:error, {:unknown_affinity, affinity}}
    end
  end

  defp find_and_click_gift(_popup, gift_id, _ctx, pass) when pass >= @max_sell_scroll_passes,
    do: {:error, {:scroll_limit, gift_id}}

  defp find_and_click_gift(popup, gift_id, ctx, pass) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, hook} <- find_hook(popup.inventory, ctx, "shop #{popup.name} scan") do
      gifts = detect_inventory_gifts(frame, hook.scan_region || hook.region, ctx)

      case Enum.find(gifts, &(&1.gift_id == gift_id)) do
        %{} = item ->
          click_item_rect(item, ctx)
          :ok

        nil ->
          if popup_at_bottom?(popup) do
            {:error, {:not_in_popup, gift_id}}
          else
            Engine.act([move_to(popup.inventory), scroll_down(@sell_scroll_clicks), sleep(@sell_scroll_settle_ms)], ctx)
            find_and_click_gift(popup, gift_id, ctx, pass + 1)
          end
      end
    end
  end

  defp popup_at_bottom?(popup) do
    checks = Engine.check_all([popup.top, popup.bottom, popup.track])
    checks[popup.bottom] or not (checks[popup.top] or checks[popup.track])
  end

  def detect_and_update_cost(ctx) do
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
