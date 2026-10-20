defmodule StarlightBot.Automation.Shop.Ops do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RewardHelpers, RunMemory}
  alias StarlightBot.Ctx
  alias StarlightBot.EgoGifts
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Teams
  alias StarlightBot.Vision.{Capture, EgoGiftDetector, HookRegistry, Matcher, NumberScanner}

  @min_item_area_px 400
  @min_classifier_conf 0.9
  @cost_read_tries 8
  @cost_read_every_ms 100
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
  @scroll_poll_ms 50
  @scroll_still_threshold 1.0
  @max_sell_scroll_passes 10
  @max_gift_search_passes 8
  @scroll_to_top_clicks 12
  @uptie_commit_result_ms 1_500
  @uptie_2_selected_ms 600

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
  @max_fuse_scroll_passes 10
  @max_affinity_attempts 5
  @heal_confirm_timeout 1_500
  @replace_popup_hook :shop_replace_popup
  @replace_confirm_hook :shop_replace_popup_confirm
  @replace_are_you_sure_hook :shop_replace_popup_are_you_sure
  @replace_purchased_hook :shop_replace_purchased
  @replace_confirm_timeout 1_500
  @replace_close_timeout 5_000
  @replace_click_offset_px 150
  @refresh_settle_ms 500
  @fuse_dismiss_offset_px 15
  @fuse_item_click_settle_ms 200
  @purchased_key :shop_purchased
  @shelf_key :shop_shelf
  @unaffordable_key :shop_unaffordable
  @fuse_affinity_key :fuse_affinity
  @fuse_change_affinity_hook :shop_fuse_popup_empty_result
  @max_escape_attempts 10
  @escape_settle_ms 400
  @fuse_popup %{
    name: "fuse",
    inventory: @fuse_inventory_hook,
    top: @fuse_scroll_top_hook,
    bottom: @fuse_scroll_bottom_hook,
    track: @fuse_scroll_track_hook
  }

  def shop_type, do: if(Engine.check(:shop_super), do: :super, else: :normal)

  def recover_to_shop(ctx) do
    if Engine.check(:shop_heal_menu), do: close_heal_menu(ctx)
    RunMemory.put(ctx, @fuse_affinity_key, nil)
    escape_to_shop(ctx, 0)
  end

  def fuse_popup_open?, do: Engine.check(@fuse_popup_hook)

  def close_fuse_popup(ctx) do
    if fuse_popup_open?() do
      recover_to_shop(ctx)
      detect_and_update_cost(ctx)
    end

    :ok
  end

  defp escape_to_shop(ctx, attempt) when attempt >= @max_escape_attempts do
    Ctx.log(ctx, :error, "shop: couldn't get back to the shop after #{attempt} esc/safe_corner attempts")
    {:error, {:retry_exhausted, :shop}}
  end

  defp escape_to_shop(ctx, attempt) do
    if Engine.check(:shop) do
      {:ok, nil}
    else
      escape_step = if rem(attempt, 2) == 0, do: key(:esc), else: click(:safe_corner)
      Engine.act([escape_step, sleep(@escape_settle_ms)], ctx)
      escape_to_shop(ctx, attempt + 1)
    end
  end

  def open_heal_menu(ctx) do
    with false <- Engine.check(:shop_heal_disabled),
         {:ok, _} <- Engine.act([click(:shop_heal), await(:shop_heal_menu)], ctx),
         false <- Engine.check(:shop_heal_disabled) do
      :ok
    else
      true -> {:error, :heal_disabled}
      {:error, _} = err -> err
    end
  end

  def close_heal_menu(ctx) do
    Engine.act([retry_until(:shop, [click(:shop_heal_return)], every: 800, tries: 5)], ctx)
  end

  def heal(:all, ctx) do
    with :ok <- heal_option_enabled(:shop_heal_every_sinner_disabled),
         :ok <- finish_heal([click(:shop_heal_every_sinner)], ctx),
         do: {:ok, :all}
  end

  def heal(sinner, ctx) do
    with :ok <- heal_option_enabled(:shop_heal_greatly_heal_disabled),
         {:ok, _} <- Engine.act([click(:shop_heal_greatly_heal)], ctx) do
      case find_healable(sinner, ctx) do
        nil -> {:error, :no_sinner_healable}
        healed -> with :ok <- finish_heal([click(:shop_heal_confirm)], ctx), do: {:ok, healed}
      end
    end
  end

  defp find_healable(sinner, ctx) do
    if heal_confirm_offered?(sinner, ctx) do
      sinner
    else
      backup = first_not_greyed_out(sinner)

      if backup do
        Ctx.log(ctx, :info, "shop heal: #{backup} isn't greyed out, using them for the backup heal")
      end

      if backup && heal_confirm_offered?(backup, ctx) do
        backup
      else
        Ctx.log(ctx, :info, "shop heal: backup heal didn't work, trying every sinner")
        Teams.all_sinners() |> Enum.reject(&(&1 in [sinner, backup])) |> Enum.find(&heal_confirm_offered?(&1, ctx))
      end
    end
  end

  defp first_not_greyed_out(skip) do
    hooks =
      for sinner <- Teams.all_sinners(),
          sinner != skip,
          hook = dead_hook(sinner),
          match?({:ok, _}, HookRegistry.find(hook)),
          do: {sinner, hook}

    greyed = Engine.check_all(Enum.map(hooks, &elem(&1, 1)))

    case Enum.find(hooks, fn {_sinner, hook} -> not greyed[hook] end) do
      nil -> nil
      {sinner, _hook} -> sinner
    end
  end

  defp dead_hook(sinner), do: :"shop_dead_#{String.replace(sinner, "_", "")}"

  def sinner_dead?(sinner) do
    hook = dead_hook(sinner)

    case HookRegistry.find(hook) do
      {:ok, _} -> Engine.check(hook)
      _ -> :no_hook
    end
  end

  def sinner_full_sp?(sinner) do
    hook = :"shop_heal_full_sp_#{String.replace(sinner, "_", "")}"

    case HookRegistry.find(hook) do
      {:ok, _} -> Engine.check(hook)
      _ -> :no_hook
    end
  end

  def revive(sinner, ctx) do
    with :ok <- heal_option_enabled(:shop_heal_revive_disabled) do
      finish_heal(
        [
          click(:shop_heal_revive),
          click(sinner_heal_hook(sinner))
        ] ++ confirm(:shop_heal_confirm, timeout: @heal_confirm_timeout),
        ctx
      )
    end
  end

  defp heal_option_enabled(disabled_hook) do
    if Engine.check(disabled_hook), do: {:error, {:option_disabled, disabled_hook}}, else: :ok
  end

  defp heal_confirm_offered?(sinner, ctx) do
    case Engine.act([click(sinner_heal_hook(sinner)), await(:shop_heal_confirm, timeout: @heal_confirm_timeout)], ctx) do
      {:ok, _} ->
        true

      {:error, _} ->
        Ctx.log(ctx, :info, "shop heal: #{sinner} can't be healed, trying the next sinner")
        false
    end
  end

  defp finish_heal(steps, ctx) do
    case Engine.act(steps ++ confirm(:shop_heal_heal_again), ctx) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp sinner_heal_hook(sinner), do: :"shop_heal_#{String.replace(sinner, "_", "")}"

  def skill_replace_offer(sinner) do
    hook = sinner_replace_hook(sinner)

    cond do
      not match?({:ok, _}, HookRegistry.find(hook)) -> :no_hook
      not Engine.check(hook) -> :not_offered
      Engine.check(@replace_purchased_hook) -> :already_purchased
      true -> :offered
    end
  end

  def replace_skill(sinner, options, ctx) do
    with :offered <- skill_replace_offer(sinner),
         {:ok, _} <- click_replace_offer(sinner, ctx),
         {:ok, _} <- Engine.act([await(@replace_popup_hook)], ctx) do
      case Enum.find(options, &replace_option_confirmed?(&1, ctx)) do
        nil ->
          {:error, :no_option_available}

        option ->
          steps = [
            retry_until(not_hook(@replace_are_you_sure_hook), [click(@replace_confirm_hook)], every: 800, tries: 3),
            await(not_hook(@replace_popup_hook), timeout: @replace_close_timeout),
            await(@sell_open_hook, timeout: @replace_close_timeout)
          ]

          case Engine.act(steps, ctx) do
            {:ok, _} -> {:ok, option}
            {:error, _} = err -> err
          end
      end
    else
      status when is_atom(status) -> {:error, status}
      {:error, _} = err -> err
    end
  end

  defp replace_option_confirmed?(option, ctx) do
    steps = [
      click(:"shop_replace_popup_#{String.replace(option, "s", "")}"),
      click(@replace_confirm_hook),
      await(@replace_are_you_sure_hook, timeout: @replace_confirm_timeout)
    ]

    case Engine.act(steps, ctx) do
      {:ok, _} ->
        true

      {:error, _} ->
        Ctx.log(ctx, :info, "shop skill replace: #{option} couldn't be confirmed, trying the next option")
        false
    end
  end

  defp click_replace_offer(sinner, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, {x, y, w, h}} <- Matcher.find(frame, sinner_replace_hook(sinner)) do
      RewardHelpers.click_rect({x, y - @replace_click_offset_px, w, h}, ctx)
    else
      :not_found -> {:error, :not_offered}
      {:error, _} = err -> err
    end
  end

  defp sinner_replace_hook(sinner), do: :"shop_replace_#{String.replace(sinner, "_", "")}"

  def check_inventory(ctx, keep_open? \\ false) do
    case open_sell_popup(ctx) do
      {:ok, _} = ok ->
        scan_visible_inventory(ctx)
        continue_scrolling_inventory(ctx, 0)
        log_inventory(ctx)
        if keep_open?, do: ok, else: close_sell_popup(ctx)

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
        scroll_and_settle(@sell_inventory_hook, scroll_down(@sell_scroll_clicks), ctx)

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
    case EgoGiftDetector.detect(frame.mat, region, classifier_conf: @min_classifier_conf, capture_tag: :shop_inventory) do
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

  def open_sell_popup(ctx), do: Engine.act([click(@sell_open_hook), await(@sell_popup_hook)], ctx)

  def close_sell_popup(ctx) do
    Engine.act([retry_until(:shop, [key(:esc)], every: 400, tries: 5)], ctx)
  end

  def refresh_shelf(ctx) do
    if Engine.check(:shop_refresh_disabled) do
      {:error, :refresh_disabled}
    else
      with {:ok, _} <- Engine.run_action(:shop, :refresh_shelf, ctx),
           {:ok, _} = ok <- Engine.act([sleep(@refresh_settle_ms)], ctx) do
        forget_shelf(ctx)
        ok
      end
    end
  end

  def reset_shop_purchases(ctx) do
    RunMemory.put(ctx, @purchased_key, [])
    forget_shelf(ctx)
  end

  def forget_shelf(ctx) do
    RunMemory.put(ctx, @shelf_key, nil)
    RunMemory.put(ctx, @unaffordable_key, %{})
  end

  def shelf_items(ctx) do
    close_fuse_popup(ctx)

    with {:ok, scanned} <- scanned_shelf(ctx) do
      purchased = RunMemory.get(ctx, @purchased_key, [])
      {bought, items} = Enum.split_with(scanned, &(&1.gift_id in purchased))

      if bought != [],
        do: Ctx.log(ctx, :info, "shop shelf: ignoring already-bought " <> Enum.map_join(Enum.uniq_by(bought, & &1.gift_id), ", ", & &1.gift_name))

      {:ok, items}
    end
  end

  defp scanned_shelf(ctx) do
    case RunMemory.get(ctx, @shelf_key, nil) do
      nil ->
        with {:ok, frame} <- Capture.grab_frame() do
          scanned = Enum.flat_map(shelf_hooks(), &detect_row(frame, &1, ctx))
          log_shelf_scan(scanned, ctx)
          RunMemory.put(ctx, @shelf_key, scanned)
          {:ok, scanned}
        end

      scanned ->
        Ctx.log(ctx, :info, "shop shelf: no refresh since the last scan, reusing it")
        {:ok, scanned}
    end
  end

  defp log_shelf_scan(scanned, ctx) do
    lines =
      Enum.map(scanned, fn item ->
        "  #{item.gift_name} (#{item.gift_id}, #{round(item.classifier_confidence * 100)}%) at " <>
          "#{round(item.x)},#{round(item.y)} #{round(item.w)}x#{round(item.h)}"
      end)

    Ctx.log(ctx, :info, Enum.join(["shop shelf scan: #{length(scanned)} item(s)" | lines], "\n"))
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
    case EgoGiftDetector.detect(frame.mat, region, classifier_conf: @min_classifier_conf, capture_tag: :shop_shelf) do
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
        {:ok, :bought} ->
          detect_and_update_cost(ctx)
          {:bought, item}

        {:ok, :insufficient_funds} -> buy_first_affordable(rest, ctx)
        _ -> :none_available
      end
    else
      buy_first_affordable(rest, ctx)
    end
  end

  def buy_item(%{gift_name: gift_name} = item, ctx) do
    seen_at = RunMemory.get(ctx, @unaffordable_key, %{})[item.gift_id]
    cost = RunMemory.cost(ctx) || 0

    if seen_at && cost <= seen_at do
      Ctx.log(ctx, :info, "shop: already saw not enough cost for #{gift_name} at #{seen_at}, skipping")
      {:ok, :insufficient_funds}
    else
      case not_enough_cost_hook(item_center(item), not_enough_cost_regions()) do
        nil -> click_to_buy(item, ctx)
        hook -> if Engine.check(hook), do: skip_unaffordable(item, hook, ctx), else: click_to_buy(item, ctx)
      end
    end
  end

  def not_enough_cost_hook({cx, cy}, regions) do
    regions
    |> Enum.filter(fn {_name, {x, y, w, h}} -> cx >= x and cx <= x + w and y + h <= cy end)
    |> Enum.max_by(fn {_name, {_x, y, _w, h}} -> y + h end, fn -> nil end)
    |> case do
      nil -> nil
      {name, _region} -> name
    end
  end

  defp not_enough_cost_regions do
    for name <- HookRegistry.all_names(),
        String.starts_with?(Atom.to_string(name), "shop_not_enough_cost_"),
        {:ok, %{region: {_, _, _, _} = region}} <- [HookRegistry.find(name)],
        do: {name, region}
  end

  defp item_center(%{x: x, y: y, w: w, h: h}), do: {x + w / 2, y + h / 2}

  defp skip_unaffordable(item, hook, ctx) do
    Ctx.log(ctx, :info, "shop: #{hook} is on, not enough cost for #{item.gift_name}, skipping")
    remember_unaffordable(item, ctx)
    {:ok, :insufficient_funds}
  end

  defp remember_unaffordable(item, ctx) do
    cost = RunMemory.cost(ctx) || 0
    RunMemory.update(ctx, @unaffordable_key, %{}, &Map.put(&1, item.gift_id, cost))
  end

  defp click_to_buy(%{gift_name: gift_name} = item, ctx) do
    Ctx.log(ctx, :info, "shop: buying #{gift_name}")

    with {:ok, _} <- RewardHelpers.click_rect({round(item.x), round(item.y), round(item.w), round(item.h)}, ctx),
         {:ok, outcome} <- await_purchase_result(ctx) do
      if outcome == :confirm, do: RunMemory.update(ctx, @purchased_key, [], &[item.gift_id | &1])
      if outcome == :insufficient_funds, do: remember_unaffordable(item, ctx)
      finish_purchase(outcome, gift_name, ctx)
    end
  end

  defp finish_purchase(:confirm, gift_name, ctx) do
    with {:ok, _} <- Engine.act([click(:shop_purchase_popup_confirm)], ctx),
         {:ok, _} <-
           Engine.act([await(:ego_gift_get), RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step()], ctx) do
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
    with {:ok, _} <- ensure_fuse_popup(ctx),
         :ok <- select_affinity(target, ctx),
         {:ok, consumed_ids} <- select_fuse_ingredients(target, click_plan, ctx),
         :ok <- confirm_fuse(ctx),
         Enum.each(consumed_ids, &RunMemory.remove_ego_gift(ctx, &1)),
         {:ok, _} <-
           Engine.act([await(:ego_gift_get), RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step()], ctx) do
      rescan_fuse_inventory(target, consumed_ids, ctx)
      :ok
    else
      {:error, reason} = err ->
        Ctx.log(ctx, :error, "shop fuse: #{target.gift_name} — #{inspect(reason)}")
        recover_to_shop(ctx)
        err
    end
  end

  defp rescan_fuse_inventory(target, consumed_ids, ctx) do
    with {:ok, _} <- Engine.act([await_any([@fuse_popup_hook, @fuse_open_hook])], ctx),
         {:ok, _} <- ensure_fuse_popup(ctx),
         :ok <- select_affinity(target, ctx) do
      before = RunMemory.ego_gifts(ctx)
      scroll_popup_to_top(@fuse_popup, ctx, 0)
      scan_fuse_inventory_pass(MapSet.new(consumed_ids), ctx, 0)
      added = for {id, %{name: name}} <- RunMemory.ego_gifts(ctx), not Map.has_key?(before, id), do: name
      Ctx.log(ctx, :info, "shop fuse rescan: " <> if(added == [], do: "nothing new", else: "added " <> Enum.join(added, ", ")))
    else
      {:error, reason} ->
        Ctx.log(ctx, :error, "shop fuse rescan: #{inspect(reason)}")
        recover_to_shop(ctx)
    end
  end

  defp ensure_fuse_popup(ctx) do
    if fuse_popup_open?() do
      {:ok, :already_open}
    else
      RunMemory.put(ctx, @fuse_affinity_key, nil)
      Engine.act([click(@fuse_open_hook), await(@fuse_popup_hook)], ctx)
    end
  end

  defp scan_fuse_inventory_pass(_consumed, ctx, pass) when pass >= @max_fuse_scroll_passes do
    Ctx.log(ctx, :error, "shop fuse rescan: hit #{@max_fuse_scroll_passes} scroll passes without reaching the bottom")
  end

  defp scan_fuse_inventory_pass(consumed, ctx, pass) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, region} <- fuse_inventory_region(frame, ctx) do
      {stale, fresh} = frame |> detect_inventory_gifts(region, ctx) |> Enum.split_with(&MapSet.member?(consumed, &1.gift_id))
      Enum.each(fresh, &record_inventory_item(&1, ctx))

      if stale != [],
        do: Ctx.log(ctx, :info, "shop fuse rescan: ignoring just-fused " <> Enum.map_join(stale, ", ", & &1.gift_name))
    end

    unless popup_at_bottom?(@fuse_popup) do
      scroll_and_settle(@fuse_inventory_hook, scroll_down(@sell_scroll_clicks), ctx)
      scan_fuse_inventory_pass(consumed, ctx, pass + 1)
    end
  end

  defp select_affinity(target, ctx, attempt \\ 0)

  defp select_affinity(_target, _ctx, attempt) when attempt >= @max_affinity_attempts,
    do: {:error, :affinity_not_selected}

  defp select_affinity(target, ctx, attempt) do
    affinity_popup_open? = Engine.check(@fuse_affinity_confirm_hook)
    keyword_unselected? = Engine.check(@fuse_select_keyword_hook)

    cond do
      not affinity_popup_open? and not keyword_unselected? and RunMemory.get(ctx, @fuse_affinity_key, nil) == target.affinity ->
        :ok

      not Map.has_key?(@affinity_hooks, target.affinity) ->
        {:error, {:unknown_affinity, target.affinity}}

      true ->
        open_steps =
          cond do
            affinity_popup_open? -> []
            keyword_unselected? -> [click(@fuse_select_keyword_hook), await(@fuse_affinity_confirm_hook)]
            true -> [click(@fuse_change_affinity_hook), await(@fuse_affinity_confirm_hook)]
          end

        steps =
          open_steps ++
            [
              click(Map.fetch!(@affinity_hooks, target.affinity)),
              click(@fuse_affinity_confirm_hook),
              await(not_hook(@fuse_affinity_confirm_hook)),
              await(@fuse_popup_hook)
            ]

        case Engine.act(steps, ctx) do
          {:ok, _} ->
            if Engine.check(@fuse_select_keyword_hook) or Engine.check(@fuse_affinity_confirm_hook) do
              Ctx.log(ctx, :info, "shop fuse: keyword still unselected after attempt #{attempt + 1}, retrying")
              select_affinity(target, ctx, attempt + 1)
            else
              RunMemory.put(ctx, @fuse_affinity_key, target.affinity)
              :ok
            end

          {:error, reason} ->
            Ctx.log(ctx, :error, "shop fuse: affinity select attempt #{attempt + 1} failed: #{inspect(reason)}")
            select_affinity(target, ctx, attempt + 1)
        end
    end
  end

  defp select_fuse_ingredients(target, {:strict, ingredient_ids}, ctx) do
    scroll_popup_to_top(@fuse_popup, ctx, 0)

    if click_fixed_shortcut(target, ctx) do
      {:ok, ingredient_ids}
    else
      select_fuse_pass({:strict, MapSet.new(ingredient_ids), MapSet.new()}, ctx, 0, false)
    end
  end

  defp click_fixed_shortcut(%{fixed_id: fixed_id, gift_name: name}, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, region} <- fuse_shortcut_region(frame, ctx),
         %{} = item <- Enum.find(detect_inventory_gifts(frame, region, ctx), &(&1.gift_id == fixed_id)) do
      click_item_rect(item, ctx)
      Engine.act([sleep(@fuse_item_click_settle_ms)], ctx)

      if Engine.check(@fuse_item_1_empty_hook) do
        Ctx.log(ctx, :info, "shop fuse: clicked the #{name} shortcut but the slots stayed empty, picking ingredients by hand")
        false
      else
        Ctx.log(ctx, :ok, "shop fuse: used the #{name} shortcut at the top of the fuse window")
        true
      end
    else
      _ ->
        Ctx.log(ctx, :info, "shop fuse: no #{name} shortcut at the top of the fuse window, picking ingredients by hand")
        false
    end
  end

  defp click_fixed_shortcut(_target, _ctx), do: false

  defp fuse_shortcut_region(frame, ctx) do
    with {:ok, hook} <- find_hook(@fuse_inventory_hook, ctx, "shop fuse shortcut scan"),
         {x, y, w, _h} = hook.scan_region || hook.region,
         {:ok, {_lx, ly, _lw, _lh}} when ly > y <- Matcher.find(frame, @fuse_owned_label_hook) do
      {:ok, {x, y, w, ly - y}}
    end
  end

  defp select_fuse_pass(_state, _ctx, pass, _dismissed?) when pass >= @max_fuse_scroll_passes do
    {:error, :fuse_scroll_limit}
  end

  defp select_fuse_pass(state, ctx, pass, dismissed?) do
    with {:ok, state_after} <- scan_and_click_fuse_items(state, ctx) do
      cond do
        fuse_selection_done?(state_after) ->
          {:ok, clicked_ids(state_after)}

        (not fuse_scrollable?() or Engine.check(@fuse_scroll_bottom_hook)) and dismissed? ->
          {:error, {:missing_ingredients, missing_ingredient_names(state_after, ctx)}}

        not fuse_scrollable?() or Engine.check(@fuse_scroll_bottom_hook) ->
          Ctx.log(ctx, :info, "shop fuse: ingredients missing, dismissing info popups and rescanning")

          with {:ok, _} <- dismiss_fuse_info_popup(ctx) do
            scroll_popup_to_top(@fuse_popup, ctx, 0)
            select_fuse_pass(state_after, ctx, pass + 1, true)
          end

        true ->
          scroll_and_settle(@fuse_inventory_hook, scroll_down(@sell_scroll_clicks), ctx)

          select_fuse_pass(state_after, ctx, pass + 1, dismissed?)
      end
    end
  end

  defp missing_ingredient_names({:strict, needed, clicked}, ctx) do
    owned = RunMemory.ego_gifts(ctx)

    needed
    |> MapSet.difference(clicked)
    |> Enum.map(fn id ->
      case owned do
        %{^id => %{name: name}} -> name
        _ -> id
      end
    end)
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

  defp dismiss_fuse_info_popup(ctx) do
    with {:ok, hook} <- find_hook(@fuse_inventory_hook, ctx, "shop fuse info popup dismiss") do
      {x, y, w, h} = hook.region || hook.scan_region
      RewardHelpers.click_rect({x + w - @fuse_dismiss_offset_px, y + h + @fuse_dismiss_offset_px, 0, 0}, ctx)
    end
  end

  defp bottom_up_right_to_left(gifts) do
    gifts
    |> Enum.sort_by(&(-(&1.y + &1.h / 2)))
    |> Enum.chunk_while(
      [],
      fn item, row ->
        case row do
          [first | _] when abs(first.y + first.h / 2 - (item.y + item.h / 2)) > first.h / 2 -> {:cont, row, [item]}
          _ -> {:cont, row ++ [item]}
        end
      end,
      fn row -> {:cont, row, []} end
    )
    |> Enum.flat_map(fn row -> Enum.sort_by(row, &(-&1.x)) end)
  end

  defp click_item_rect(item, ctx) do
    RewardHelpers.click_rect({round(item.x), round(item.y), round(item.w), round(item.h)}, ctx)
  end

  defp click_matching_fuse_items({:strict, needed, clicked}, gifts, ctx) do
    clicked_after =
      gifts
      |> bottom_up_right_to_left()
      |> Enum.reduce(clicked, fn item, acc ->
        if MapSet.member?(needed, item.gift_id) and not MapSet.member?(acc, item.gift_id) do
          click_item_rect(item, ctx)
          Engine.act([sleep(@fuse_item_click_settle_ms)], ctx)
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
    with :ok <- find_and_click_gift(@sell_popup, gift_id, ctx),
         {:ok, _} <-
           Engine.act(
             [click(:shop_sell_popup_confirm)] ++
               confirm_enter(:shop_sell_popup_confirm_confirm) ++
               [await(@sell_popup_hook)],
             ctx
           ) do
      RunMemory.remove_ego_gift(ctx, gift_id)
      :ok
    else
      {:error, reason} = err ->
        Ctx.log(ctx, :error, "shop sell: #{gift_id} — #{inspect(reason)}")
        err
    end
  end

  def uptie_gift(gift_id, from, to, ctx) do
    with {:ok, _} <- open_uptie_popup(ctx),
         :ok <- find_and_click_gift(@uptie_popup, gift_id, ctx),
         {:ok, _} <- Engine.act([click(:shop_uptie_popup_confirm), await(:shop_uptie_popup_commit_confirm)], ctx) do
      commit_uptie(from, to, ctx)
    else
      {:error, reason} = err ->
        Ctx.log(ctx, :error, "shop uptie: #{gift_id} — #{inspect(reason)}")
        err
    end
  end

  defp open_uptie_popup(ctx) do
    if Engine.check(:shop_uptie_popup),
      do: {:ok, :already_open},
      else: Engine.act([click(:shop_uptie), await(:shop_uptie_popup)], ctx)
  end

  defp commit_uptie(from, to, ctx) do
    attempt = if to == 1, do: commit_default_uptie(ctx), else: try_commit(to, ctx)

    case attempt do
      {:committed, level} ->
        {:ok, level}

      :rejected when to == 2 and from == 0 ->
        Ctx.log(ctx, :info, "shop uptie: +2 didn't go through, trying +1")

        case try_commit(1, ctx) do
          {:committed, level} -> {:ok, level}
          :rejected -> cancel_commit(ctx)
        end

      :rejected ->
        cancel_commit(ctx)
    end
  end

  defp commit_default_uptie(ctx) do
    Engine.act([key(:enter)], ctx)
    await_commit(1, ctx)
  end

  defp try_commit(2, ctx) do
    steps = [
      click(:shop_uptie_popup_commit_uptie_2),
      await(:shop_uptie_popup_commit_uptie_2_selected, timeout: @uptie_2_selected_ms),
      click(:shop_uptie_popup_commit_confirm)
    ]

    level =
      case Engine.act(steps, ctx) do
        {:ok, _} ->
          2

        {:error, _} ->
          Ctx.log(ctx, :info, "shop uptie: +2 isn't selected, confirming at +1")
          Engine.act([click(:shop_uptie_popup_commit_confirm)], ctx)
          1
      end

    await_commit(level, ctx)
  end

  defp try_commit(level, ctx) do
    Engine.act([click(:"shop_uptie_popup_commit_uptie_#{level}"), click(:shop_uptie_popup_commit_confirm)], ctx)
    await_commit(level, ctx)
  end

  defp await_commit(level, ctx) do
    case Engine.act([await(not_hook(:shop_uptie_popup_commit_cancel), timeout: @uptie_commit_result_ms)], ctx) do
      {:ok, _} -> {:committed, level}
      {:error, _} -> :rejected
    end
  end

  defp cancel_commit(ctx) do
    Engine.act([reclick_until_gone(:shop_uptie_popup_commit_cancel)], ctx)
    {:error, :cant_afford}
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
               await(not_hook(:shop_keyword_refresh_popup)),
               sleep(@refresh_settle_ms)
             ],
             ctx
           ) do
      forget_shelf(ctx)
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

  defp find_and_click_gift(popup, gift_id, ctx) do
    case click_visible_gift(popup, gift_id, ctx) do
      :not_visible ->
        scroll_popup_to_top(popup, ctx, 0)
        scan_down_and_click(popup, gift_id, ctx, 0)

      result ->
        result
    end
  end

  defp click_visible_gift(popup, gift_id, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, hook} <- find_hook(popup.inventory, ctx, "shop #{popup.name} scan") do
      case Enum.find(detect_inventory_gifts(frame, hook.scan_region || hook.region, ctx), &(&1.gift_id == gift_id)) do
        %{} = item ->
          click_item_rect(item, ctx)
          :ok

        nil ->
          :not_visible
      end
    end
  end

  defp scan_down_and_click(_popup, gift_id, _ctx, pass) when pass >= @max_gift_search_passes,
    do: {:error, {:scroll_limit, gift_id}}

  defp scan_down_and_click(popup, gift_id, ctx, pass) do
    case click_visible_gift(popup, gift_id, ctx) do
      :not_visible ->
        if popup_at_bottom?(popup) do
          {:error, {:not_in_popup, gift_id}}
        else
          scroll_and_settle(popup.inventory, scroll_down(@sell_scroll_clicks), ctx)
          scan_down_and_click(popup, gift_id, ctx, pass + 1)
        end

      result ->
        result
    end
  end

  defp scroll_popup_to_top(_popup, _ctx, pass) when pass >= @max_sell_scroll_passes, do: :ok

  defp scroll_popup_to_top(popup, ctx, pass) do
    checks = Engine.check_all([popup.top, popup.bottom, popup.track])

    if checks[popup.top] or not (checks[popup.bottom] or checks[popup.track]) do
      :ok
    else
      scroll_and_settle(popup.inventory, scroll_up(@scroll_to_top_clicks), ctx)
      scroll_popup_to_top(popup, ctx, pass + 1)
    end
  end

  defp scroll_and_settle(inventory_hook, scroll_step, ctx) do
    with {:ok, _} <- Engine.act([move_to(inventory_hook)], ctx),
         {:ok, %{} = hook} <- HookRegistry.find(inventory_hook),
         {:ok, before} <- Capture.grab_frame(),
         {:ok, _} = ok <- Engine.act([scroll_step], ctx) do
      deadline = System.monotonic_time(:millisecond) + @sell_scroll_settle_ms
      await_scroll_settled(hook.scan_region || hook.region, before, nil, deadline)
      ok
    end
  end

  defp await_scroll_settled(region, before, previous, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(@scroll_poll_ms)

      case Capture.grab_frame() do
        {:ok, frame} ->
          cond do
            previous == nil and same_region?(frame, before, region) -> await_scroll_settled(region, before, nil, deadline)
            previous != nil and same_region?(frame, previous, region) -> :ok
            true -> await_scroll_settled(region, before, frame, deadline)
          end

        {:error, _} ->
          await_scroll_settled(region, before, previous, deadline)
      end
    end
  end

  defp same_region?(a, b, region) do
    {c0, c1, c2, _} = Evision.mean(Evision.absdiff(Evision.Mat.roi(a.mat, region), Evision.Mat.roi(b.mat, region)))
    max(c0, max(c1, c2)) < @scroll_still_threshold
  end

  defp popup_at_bottom?(popup) do
    checks = Engine.check_all([popup.top, popup.bottom, popup.track])
    checks[popup.bottom] or not (checks[popup.top] or checks[popup.track])
  end

  def detect_and_update_cost(ctx), do: detect_and_update_cost(@cost_read_tries, ctx)

  defp detect_and_update_cost(tries_left, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, cost} <- NumberScanner.read(frame) do
      Ctx.log(ctx, :info, "cost: read #{cost}")
      RunMemory.put_cost(ctx, cost)
    else
      _ when tries_left > 1 ->
        Process.sleep(@cost_read_every_ms)
        detect_and_update_cost(tries_left - 1, ctx)

      other ->
        Ctx.log(ctx, :error, "cost: read failed after #{@cost_read_tries} tries (#{inspect(other)})")
        :ok
    end
  end
end
