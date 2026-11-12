defmodule StarlightBot.Automation.Shop.Ops do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RewardHelpers, RunMemory}
  alias StarlightBot.Ctx
  alias StarlightBot.EgoGifts
  alias StarlightBot.FailureShot
  alias StarlightBot.GiftPlans
  alias StarlightBot.Input.{Leeway, Mouse}
  alias StarlightBot.Teams
  alias StarlightBot.Vision.{Capture, EgoGiftDetector, Frame, HookRegistry, Matcher, NumberScanner}

  @min_item_area_px 1000
  @min_classifier_conf 0.95
  @cost_read_tries 12
  @cost_read_every_ms 50
  @uptie_extend_px 50
  @uptie_2_hook :shop_sell_popup_uptie_2
  @uptie_1_hook :shop_sell_popup_uptie_1
  @purchase_result_timeout 5_000
  @extra_gift_get_timeout 1_500
  @chance_comet_min_tier 3
  @normal_shelf_hooks [:shop_shelf_row_1, :shop_shelf_row_2]
  @super_shelf_hooks [:shop_super_shelf_row_1, :shop_super_shelf_row_2]

  @sell_open_hook :shop_sell
  @sell_popup_hook :shop_sell_popup
  @sell_inventory_hook :shop_sell_popup_inventory
  @sell_scroll_top_hook :shop_sell_popup_scroll_top
  @sell_scroll_bottom_hook :shop_sell_popup_scroll_bottom
  @sell_scroll_track_hook :shop_sell_popup_scroll_track
  @sell_scroll_hooks [@sell_scroll_top_hook, @sell_scroll_bottom_hook, @sell_scroll_track_hook]
  @sell_nothing_selected_hook :shop_sell_popup_nothing_selected
  @sell_select_check_ms 800
  @sell_select_tries 3
  @sell_scroll_clicks 4
  @sell_scroll_settle_ms 700
  @sell_close_every_ms 900
  @sell_confirm_steady_ms 200
  @sell_confirm_steady_timeout_ms 1_500
  @sell_confirm_retry_ms 1_200
  @sell_confirm_tries 3
  @sell_confirm_confirm_hook :shop_sell_popup_confirm_confirm
  @sell_gift_passes_key :shop_sell_gift_passes
  @sell_popup_pass_key :shop_sell_popup_pass
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
  @fuse_open_retry_ms 1_500
  @fuse_open_tries 4
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
  @fuse_merge_area_hook :shop_fuse_popup_merge_area
  @fuse_dismiss_info_hook :shop_fuse_popup_dismiss_gift_info_popup
  @fuse_merge_retries 3
  @fuse_merge_settle_ms 300
  @fuse_confirm_confirm_hooks [:shop_fuse_popup_confirm_confirm, :shop_fuse_popup_confirm_confirm_2]
  @max_fuse_scroll_passes 10
  @max_affinity_attempts 5
  @heal_confirm_timeout 1_200
  @heal_select_retry_ms 1_000
  @heal_result_timeout 5_000
  @replace_popup_hook :shop_replace_popup
  @replace_confirm_hook :shop_replace_popup_confirm
  @replace_are_you_sure_hook :shop_replace_popup_are_you_sure
  @replace_purchased_hook :shop_replace_purchased
  @replace_confirm_timeout 1_500
  @replace_close_timeout 5_000
  @replace_click_offset_px 150
  @new_shelf_timeout_ms 2_000
  @new_shelf_poll_ms 100
  @shelf_settle_timeout_ms 1_000
  @fuse_dismiss_offset_px 15
  @fuse_item_click_settle_ms 130
  @fuse_rise_min_px 1
  @fuse_slots_filled_ms 1_000
  @fuse_confirm_steady_ms 120
  @fuse_confirm_steady_timeout_ms 1_500
  @fuse_confirm_retry_ms 1_200
  @fuse_confirm_tries 3
  @purchased_key :shop_purchased
  @buy_count_key :shop_buy_count
  @refresh_lock_normal 4
  @refresh_lock_super 6
  @shelf_key :shop_shelf
  @unaffordable_key :shop_unaffordable
  @fuse_affinity_key :fuse_affinity
  @chance_comet_used_key :shop_chance_comet_used
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
    escape_to_shop(ctx, if(Engine.check(:shop_uptie_popup), do: 1, else: 0))
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
      escape_step = if rem(attempt, 2) == 0 and not click_dismissed_popup_open?(), do: key(:esc), else: click(:safe_corner)
      Engine.act([escape_step, branch([{:shop, []}], wait: @escape_settle_ms)], ctx)
      escape_to_shop(ctx, attempt + 1)
    end
  end

  defp click_dismissed_popup_open?, do: Engine.check(@replace_popup_hook) or Engine.check(:shop_purchase_popup)

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
        healed -> with :ok <- finish_heal([], ctx), do: {:ok, healed}
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

  def sinner_statuses(sinners) do
    hooks =
      sinners
      |> Enum.flat_map(&[dead_hook(&1), full_hook(&1, :sp), full_hook(&1, :hp)])
      |> Enum.filter(&match?({:ok, _}, HookRegistry.find(&1)))

    checks = Engine.check_all(hooks)

    Map.new(sinners, fn sinner ->
      full = Map.get(checks, full_hook(sinner, :sp), false) and Map.get(checks, full_hook(sinner, :hp), false)
      {sinner, %{dead: Map.get(checks, dead_hook(sinner), false), full: full}}
    end)
  end

  def sinner_full?(sinner, stat) do
    hook = full_hook(sinner, stat)

    case HookRegistry.find(hook) do
      {:ok, _} -> Engine.check(hook)
      _ -> :no_hook
    end
  end

  def sinner_full_reading(sinner) do
    hooks = Enum.map([:sp, :hp], &full_hook(sinner, &1))

    with true <- Enum.all?(hooks, &match?({:ok, _}, HookRegistry.find(&1))),
         {:ok, frame} <- Capture.grab_frame() do
      Enum.map(hooks, fn hook ->
        {:ok, score, result} = Matcher.find_with_score(frame, hook)
        {score, result != :not_found}
      end)
    else
      _ -> :no_reading
    end
  end

  defp full_hook(sinner, stat), do: :"shop_heal_full_#{stat}_#{String.replace(sinner, "_", "")}"

  def revive(sinner, ctx) do
    with :ok <- heal_option_enabled(:shop_heal_revive_disabled) do
      finish_heal(
        [
          click(:shop_heal_revive),
          click(sinner_heal_hook(sinner), settle_ms: 100),
          await(:shop_heal_confirm, timeout: @heal_confirm_timeout)
        ],
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
    select_until_healed =
      retry_until(:shop_heal_heal_again, [branch([{all_of([:shop_heal_confirm, not_hook(:shop_heal_heal_again)]), [click(:shop_heal_confirm)]}])], every: @heal_select_retry_ms, timeout: @heal_result_timeout)

    case Engine.act(steps ++ [select_until_healed | confirm(:shop_heal_heal_again)], ctx) do
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
          {:error, {:no_option_available, options}}

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
        RunMemory.put(ctx, @sell_gift_passes_key, %{})
        stack_counts = continue_scrolling_inventory(ctx, 0, scan_visible_inventory(ctx, 0))
        Enum.each(stack_counts, fn {gift_id, count} -> RunMemory.set_ego_gift_count(ctx, gift_id, count) end)
        log_inventory(ctx)
        if keep_open?, do: ok, else: close_sell_popup(ctx)

      {:error, _} = err ->
        err
    end
  end

  defp continue_scrolling_inventory(ctx, pass, stack_counts) when pass >= @max_sell_scroll_passes do
    Ctx.log(ctx, :error, "shop sell inventory scan: hit #{@max_sell_scroll_passes} scroll passes without reaching the bottom")
    stack_counts
  end

  defp continue_scrolling_inventory(ctx, pass, stack_counts) do
    checks = Engine.check_all(@sell_scroll_hooks)
    scrollable? = checks[@sell_scroll_top_hook] or checks[@sell_scroll_bottom_hook] or checks[@sell_scroll_track_hook]

    cond do
      not scrollable? ->
        stack_counts

      checks[@sell_scroll_bottom_hook] ->
        stack_counts

      scroll_and_settle(@sell_inventory_hook, scroll_down(@sell_scroll_clicks), ctx) == :unmoved ->
        stack_counts

      true ->
        RunMemory.put(ctx, @sell_popup_pass_key, pass + 1)

        frame_counts = scan_visible_inventory(ctx, pass + 1)
        continue_scrolling_inventory(ctx, pass + 1, Map.merge(stack_counts, frame_counts, fn _id, a, b -> max(a, b) end))
    end
  end

  defp scan_visible_inventory(ctx, pass) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, hook} <- find_hook(@sell_inventory_hook, ctx, "shop sell inventory scan") do
      gifts = detect_inventory_gifts(frame, hook.scan_region || hook.region, ctx)
      Enum.each(gifts, &record_inventory_item(&1, ctx))
      record_gift_passes(gifts, pass, ctx)
      assign_uptie_level(frame, gifts, @uptie_2_hook, 2, ctx)
      assign_uptie_level(frame, gifts, @uptie_1_hook, 1, ctx)

      gifts
      |> Enum.filter(&EgoGifts.stackable?(&1.gift_name))
      |> Enum.frequencies_by(& &1.gift_id)
    else
      {:error, reason} ->
        Ctx.log(ctx, :error, "shop sell inventory scan: #{inspect(reason)}")
        %{}
    end
  end

  defp record_gift_passes(gifts, pass, ctx) do
    RunMemory.update(ctx, @sell_gift_passes_key, %{}, fn passes ->
      Enum.reduce(gifts, passes, fn %{gift_id: id}, acc -> Map.update(acc, id, {pass, pass}, fn {first, _} -> {first, pass} end) end)
    end)
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
    case EgoGiftDetector.detect(frame.mat, region, classifier_conf: @min_classifier_conf) do
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
    names = RunMemory.ego_gifts(ctx) |> Map.values() |> Enum.map(&if(&1.count > 1, do: "#{&1.name} x#{&1.count}", else: &1.name)) |> Enum.sort()
    Ctx.log(ctx, :ok, "shop sell inventory: #{length(names)} item(s) owned: #{Enum.join(names, ", ")}")
  end

  def open_sell_popup(ctx) do
    with {:ok, _} = ok <- Engine.act([click(@sell_open_hook, settle_ms: 100), await(@sell_popup_hook)], ctx) do
      RunMemory.put(ctx, @sell_popup_pass_key, 0)
      ok
    end
  end

  def close_sell_popup(ctx) do
    Engine.act([retry_until(:shop, [key(:esc)], every: @sell_close_every_ms, tries: 5, retry_if: @sell_popup_hook)], ctx)
  end

  def refresh_shelf(ctx) do
    if Engine.check(:shop_refresh_disabled) do
      {:error, :refresh_disabled}
    else
      with {:ok, before} <- settled_shelf_scan(ctx),
           {:ok, _} = ok <- Engine.run_action(:shop, :refresh_shelf, ctx) do
        forget_shelf(ctx)
        forget_slot_purchases(ctx)
        await_new_shelf(before, ctx)
        ok
      end
    end
  end

  def reset_shop_purchases(ctx) do
    RunMemory.put(ctx, @purchased_key, [])
    forget_shelf(ctx)
  end

  def reset_buy_count(ctx), do: RunMemory.put(ctx, @buy_count_key, 0)

  def refresh_locked?(shop_type, ctx) do
    RunMemory.get(ctx, @buy_count_key, 0) >= if(shop_type == :super, do: @refresh_lock_super, else: @refresh_lock_normal)
  end

  def forget_shelf(ctx) do
    RunMemory.put(ctx, @shelf_key, nil)
    RunMemory.put(ctx, @unaffordable_key, %{})
  end

  defp forget_slot_purchases(ctx), do: RunMemory.update(ctx, @purchased_key, [], &Enum.filter(&1, fn entry -> is_binary(entry) end))

  def shelf_items(ctx) do
    close_fuse_popup(ctx)

    with {:ok, scanned} <- scanned_shelf(ctx) do
      purchased = RunMemory.get(ctx, @purchased_key, [])
      {bought, items} = Enum.split_with(scanned, &(purchase_key(&1) in purchased))

      if bought != [],
        do: Ctx.log(ctx, :info, "shop shelf: ignoring already-bought " <> Enum.map_join(Enum.uniq_by(bought, & &1.gift_id), ", ", & &1.gift_name))

      {:ok, items}
    end
  end

  defp scanned_shelf(ctx) do
    case RunMemory.get(ctx, @shelf_key, nil) do
      nil ->
        with {:ok, scanned} <- settled_shelf_scan(ctx) do
          log_shelf_scan(scanned, ctx)
          RunMemory.put(ctx, @shelf_key, scanned)
          {:ok, scanned}
        end

      scanned ->
        Ctx.log(ctx, :info, "shop shelf: no refresh since the last scan, reusing it")
        {:ok, scanned}
    end
  end

  defp settled_shelf_scan(ctx) do
    settled_shelf_scan(nil, System.monotonic_time(:millisecond) + @shelf_settle_timeout_ms, ctx)
  end

  defp settled_shelf_scan(previous, deadline, ctx) do
    with {:ok, frame} <- Capture.grab_frame() do
      scanned = Enum.flat_map(shelf_hooks(), &detect_row(frame, &1, ctx))

      cond do
        previous != nil and shelf_signature(scanned) == shelf_signature(previous) ->
          {:ok, scanned}

        System.monotonic_time(:millisecond) >= deadline ->
          Ctx.log(ctx, :info, "shop shelf: scans still changing after #{@shelf_settle_timeout_ms}ms, using the last one")
          {:ok, scanned}

        true ->
          Mouse.dwell(@new_shelf_poll_ms)
          settled_shelf_scan(scanned, deadline, ctx)
      end
    end
  end

  defp await_new_shelf(before, ctx) do
    started_at = System.monotonic_time(:millisecond)
    before_ids = MapSet.new(before, & &1.gift_id)
    poll_new_shelf(before_ids, nil, started_at, started_at + @new_shelf_timeout_ms, ctx)
  end

  defp poll_new_shelf(before_ids, previous, started_at, deadline, ctx) do
    scanned =
      case Capture.grab_frame() do
        {:ok, frame} -> Enum.flat_map(shelf_hooks(), &detect_row(frame, &1, ctx))
        {:error, _} -> []
      end

    signature = shelf_signature(scanned)
    new_items? = not MapSet.subset?(MapSet.new(scanned, & &1.gift_id), before_ids)

    cond do
      new_items? and signature == previous ->
        Ctx.log(ctx, :info, "shop shelf: new shelf settled #{System.monotonic_time(:millisecond) - started_at}ms after refresh")
        log_shelf_scan(scanned, ctx)
        RunMemory.put(ctx, @shelf_key, scanned)

      System.monotonic_time(:millisecond) >= deadline ->
        Ctx.log(ctx, :info, "shop shelf: no settled new shelf within #{@new_shelf_timeout_ms}ms of refresh, moving on")

      true ->
        Mouse.dwell(@new_shelf_poll_ms)
        poll_new_shelf(before_ids, signature, started_at, deadline, ctx)
    end
  end

  defp shelf_signature(items) do
    items
    |> Enum.map(&{&1.gift_id, shelf_slot(&1)})
    |> Enum.sort()
  end

  defp shelf_slot(item), do: {round(item.x / 50), round(item.y / 50)}

  defp purchase_key(item) do
    if EgoGifts.stackable?(item.gift_name), do: {item.gift_id, shelf_slot(item)}, else: item.gift_id
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
    case EgoGiftDetector.detect(frame.mat, region, classifier_conf: @min_classifier_conf) do
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
          RunMemory.put(ctx, @shelf_key, nil)
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
    owned_before = RunMemory.ego_gift_count(ctx, item.gift_id)

    with {:ok, _} <- RewardHelpers.click_rect({round(item.x), round(item.y), round(item.w), round(item.h)}, ctx),
         {:ok, outcome} <- await_purchase_result(ctx) do
      if outcome == :confirm, do: RunMemory.update(ctx, @purchased_key, [], &[purchase_key(item) | &1])
      if outcome == :insufficient_funds, do: remember_unaffordable(item, ctx)
      result = finish_purchase(outcome, gift_name, ctx)

      if result == {:ok, :bought} and EgoGifts.stackable?(gift_name) and RunMemory.ego_gift_count(ctx, item.gift_id) > 0,
        do: RunMemory.set_ego_gift_count(ctx, item.gift_id, owned_before + 1)

      result
    end
  end

  defp finish_purchase(:confirm, gift_name, ctx) do
    with {:ok, _} <- Engine.act([click(:shop_purchase_popup_confirm)], ctx),
         {:ok, _} <-
           Engine.act([await(:ego_gift_get), RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step()], ctx) do
      RunMemory.update(ctx, @buy_count_key, 0, &(&1 + 1))
      Ctx.log(ctx, :ok, "shop: bought #{gift_name}")
      {:ok, :bought}
    end
  end

  defp finish_purchase(:insufficient_funds, gift_name, ctx) do
    Ctx.log(ctx, :info, "shop: not enough cost for #{gift_name} — backing out")

    case Engine.act([click(:safe_corner)], ctx) do
      {:ok, _} -> {:ok, :insufficient_funds}
      {:error, _} = err -> err
    end
  end

  defp await_purchase_result(ctx) do
    steps = [await_any([:shop_purchase_popup_confirm, :shop_purchase_pop_gift_info], timeout: @purchase_result_timeout)]

    case Engine.act(steps, ctx) do
      {:ok, :shop_purchase_pop_gift_info} -> {:ok, :insufficient_funds}
      {:ok, :shop_purchase_popup_confirm} -> {:ok, :confirm}
      {:error, _} = err -> err
    end
  end

  def perform_fusion(target, click_plan, ctx) do
    forget_shelf(ctx)

    with {:ok, consumed_ids} <- stage_fusion(target, click_plan, ctx, 0),
         :ok <- confirm_fuse(ctx),
         Enum.each(consumed_ids, &RunMemory.remove_ego_gift(ctx, &1)),
         {:ok, _} <-
           Engine.act(
             [await(:ego_gift_get), RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step(leaving: :ego_gift_get)],
             ctx
           ),
         {:ok, _} <- collect_chance_comet_gift(target, ctx),
         {:ok, _} <- Engine.act([await_any([@fuse_popup_hook, @fuse_open_hook])], ctx) do
      :ok
    else
      {:error, reason} = err ->
        Ctx.log(ctx, :error, "shop fuse: #{target.gift_name} — #{inspect(reason)}")
        FailureShot.record("shop_fuse_#{target.gift_name}", ctx)
        recover_to_shop(ctx)
        err
    end
  end

  def chance_comet_ready?(plan, result_tier, ctx) do
    result_tier >= @chance_comet_min_tier and GiftPlans.chance_comet?(plan) and not RunMemory.get(ctx, @chance_comet_used_key, false)
  end

  def reset_chance_comet(ctx), do: RunMemory.put(ctx, @chance_comet_used_key, false)

  defp collect_chance_comet_gift(%{chance_comet?: true}, ctx) do
    if Engine.check_within(:ego_gift_get, @extra_gift_get_timeout) do
      Ctx.log(ctx, :info, "shop fuse: Chance Comet extra ego gift, collecting it")
      RunMemory.put(ctx, @chance_comet_used_key, true)
      Engine.act([RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step(leaving: :ego_gift_get)], ctx)
    else
      {:ok, nil}
    end
  end

  defp collect_chance_comet_gift(_target, _ctx), do: {:ok, nil}

  defp stage_fusion(target, click_plan, ctx, attempt) do
    with {:ok, _} <- ensure_fuse_popup(ctx),
         :ok <- select_affinity(target, ctx),
         {:ok, ids} <- select_fuse_ingredients(target, click_plan, ctx) do
      settle_merge_area(target, click_plan, ids, ctx, attempt)
    end
  end

  defp settle_merge_area(target, click_plan, ids, ctx, attempt) do
    needed = Enum.frequencies(ids)

    case merge_area_status(needed, ctx) do
      :ok ->
        {:ok, ids}

      {:error, _} = err ->
        err

      _ when attempt >= @fuse_merge_retries ->
        Ctx.log(ctx, :error, "shop fuse: merge area still doesn't match the ingredients after #{attempt} retries")
        {:error, :merge_area_mismatch}

      {:extras, extras} ->
        reopen_fuse_popup(target, click_plan, ctx, attempt, "unexpected gifts in the merge area (#{Enum.join(extras, ", ")})")

      {:missing, _} ->
        with {:ok, _} <- Engine.act([click(@fuse_dismiss_info_hook, missing: :ok)], ctx) do
          recheck_merge_area(target, click_plan, ids, needed, ctx, attempt)
        end
    end
  end

  defp recheck_merge_area(target, click_plan, ids, needed, ctx, attempt) do
    case merge_area_status(needed, ctx) do
      :ok ->
        {:ok, ids}

      {:error, _} = err ->
        err

      {:extras, extras} ->
        reopen_fuse_popup(target, click_plan, ctx, attempt, "unexpected gifts in the merge area (#{Enum.join(extras, ", ")})")

      {:missing, missing} ->
        Ctx.log(ctx, :info, "shop fuse: merge area is missing #{Enum.join(Map.keys(missing), ", ")}, clicking them again (retry #{attempt + 1}/#{@fuse_merge_retries})")
        scroll_popup_to_bottom(@fuse_popup, ctx, 0)

        case select_fuse_pass({:strict, missing, %{}}, ctx, 0, true) do
          {:ok, _} -> settle_merge_area(target, click_plan, ids, ctx, attempt + 1)
          {:error, reason} -> reopen_fuse_popup(target, click_plan, ctx, attempt, "re-click failed: #{inspect(reason)}")
        end
    end
  end

  defp reopen_fuse_popup(target, click_plan, ctx, attempt, why) do
    Ctx.log(ctx, :info, "shop fuse: #{why}, reopening the fuse popup (retry #{attempt + 1}/#{@fuse_merge_retries})")
    recover_to_shop(ctx)
    stage_fusion(target, click_plan, ctx, attempt + 1)
  end

  defp merge_area_status(needed, ctx) do
    Engine.act([sleep(@fuse_merge_settle_ms)], ctx)

    with {:ok, hook} <- find_hook(@fuse_merge_area_hook, ctx, "shop fuse merge area scan"),
         {:ok, frame} <- Capture.grab_frame() do
      found = frame |> detect_inventory_gifts(hook.scan_region || hook.region, ctx) |> Enum.frequencies_by(& &1.gift_id)
      missing = for {id, n} <- needed, Map.get(found, id, 0) < n, into: %{}, do: {id, n - Map.get(found, id, 0)}
      extras = for {id, n} <- found, n > Map.get(needed, id, 0), do: id

      cond do
        map_size(missing) == 0 -> :ok
        extras != [] -> {:extras, extras}
        true -> {:missing, missing}
      end
    end
  end

  defp ensure_fuse_popup(ctx) do
    if fuse_popup_open?() do
      {:ok, :already_open}
    else
      RunMemory.put(ctx, @fuse_affinity_key, nil)
      Engine.act([retry_until(@fuse_popup_hook, [click(@fuse_open_hook, settle_ms: 100)], every: @fuse_open_retry_ms, tries: @fuse_open_tries, retry_if: @fuse_open_hook)], ctx)
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

      is_nil(fuse_affinity_hook(target.affinity)) ->
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
              click(fuse_affinity_hook(target.affinity)),
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
      scroll_popup_to_bottom(@fuse_popup, ctx, 0)
      select_fuse_pass({:strict, Enum.frequencies(ingredient_ids), %{}}, ctx, 0, false)
    end
  end

  defp click_fixed_shortcut(%{fixed_id: fixed_id, gift_name: name}, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, region} <- fuse_shortcut_region(frame, ctx),
         %{} = item <- Enum.find(detect_inventory_gifts(frame, region, ctx), &(&1.gift_id == fixed_id)) do
      click_item_rect(item, ctx)
      Engine.act([sleep(@fuse_item_click_settle_ms)], ctx)

      if not Engine.check_within(not_hook(@fuse_item_1_empty_hook), @fuse_slots_filled_ms) do
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

        not fuse_scrollable?() or Engine.check(@fuse_scroll_top_hook) ->
          fuse_top_reached(state_after, ctx, pass, dismissed?)

        true ->
          case scroll_and_settle(@fuse_inventory_hook, scroll_up(@sell_scroll_clicks), ctx) do
            :unmoved -> fuse_top_reached(state_after, ctx, pass, dismissed?)
            _ -> select_fuse_pass(state_after, ctx, pass + 1, dismissed?)
          end
      end
    end
  end

  defp fuse_top_reached(state, ctx, _pass, true) do
    names = missing_ingredient_names(state, ctx)
    RunMemory.add_unfusable_gifts(ctx, missing_ingredient_ids(state))
    Ctx.log(ctx, :info, "shop fuse: #{Enum.join(names, ", ")} never showed up in the fuse window, leaving it out of tiered fusions for the rest of the run")
    {:error, {:missing_ingredients, names}}
  end

  defp fuse_top_reached(state, ctx, pass, false) do
    Ctx.log(ctx, :info, "shop fuse: ingredients missing, dismissing info popups and rescanning")

    with {:ok, _} <- dismiss_fuse_info_popup(ctx) do
      scroll_popup_to_bottom(@fuse_popup, ctx, 0)
      select_fuse_pass(state, ctx, pass + 1, true)
    end
  end

  defp missing_ingredient_names(state, ctx) do
    owned = RunMemory.ego_gifts(ctx)

    state
    |> missing_ingredient_ids()
    |> Enum.map(fn id ->
      case owned do
        %{^id => %{name: name}} -> name
        _ -> id
      end
    end)
  end

  defp missing_ingredient_ids({:strict, needed, clicked}) do
    for {id, n} <- needed, Map.get(clicked, id, 0) < n, do: id
  end

  defp fuse_selection_done?(state), do: missing_ingredient_ids(state) == []

  defp clicked_ids({_kind, _needed, clicked}), do: Enum.flat_map(clicked, fn {id, n} -> List.duplicate(id, n) end)

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
      Enum.each(gifts, &record_inventory_item(&1, ctx))
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
    |> Enum.map(fn row -> Enum.sort_by(row, &(-&1.x)) end)
  end

  defp click_item_rect(item, ctx) do
    RewardHelpers.click_rect({round(item.x), round(item.y), round(item.w), round(item.h)}, ctx)
  end

  defp click_item_rising(item, index, count, prev_y, ctx) do
    {cx, cy} = Leeway.in_rect({item.x, item.y, item.w, item.h})
    ramp = ((count - 1) / 2 - index) * item.h / (count * 6)
    y = min(cy + ramp, (prev_y || cy + ramp) - @fuse_rise_min_px)
    y = y |> max(item.y + 1) |> min(item.y + item.h - 1)
    RewardHelpers.click_point({cx, y}, ctx)
    y
  end

  defp click_matching_fuse_items({:strict, needed, clicked}, gifts, ctx) do
    rows = bottom_up_right_to_left(gifts)
    visible = rows |> List.flatten() |> Enum.frequencies_by(& &1.gift_id)

    takeable =
      for {id, n} <- needed, not Map.has_key?(clicked, id), Map.get(visible, id, 0) >= n, into: %{}, do: {id, n}

    {clicked_after, _} =
      Enum.reduce(rows, {clicked, nil}, fn row, {acc, _prev_y} ->
        count = length(row)

        row
        |> Enum.with_index()
        |> Enum.reduce({acc, nil}, fn {item, index}, {acc, prev_y} ->
          if Map.get(acc, item.gift_id, 0) < Map.get(takeable, item.gift_id, 0) do
            y = click_item_rising(item, index, count, prev_y, ctx)
            Engine.act([sleep(@fuse_item_click_settle_ms)], ctx)
            {Map.update(acc, item.gift_id, 1, &(&1 + 1)), y}
          else
            {acc, prev_y}
          end
        end)
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
    steps = [
      key(:enter),
      await(any_of(@fuse_confirm_confirm_hooks)),
      hold(any_of(@fuse_confirm_confirm_hooks), @fuse_confirm_steady_ms, within: @fuse_confirm_steady_timeout_ms),
      retry_until(not_hook(any_of(@fuse_confirm_confirm_hooks)), [key(:enter)],
        every: @fuse_confirm_retry_ms,
        tries: @fuse_confirm_tries,
        retry_if: any_of(@fuse_confirm_confirm_hooks)
      )
    ]

    case Engine.act(steps, ctx) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  def sell_gift(gift_id, ctx) do
    with :ok <- select_sell_gift(gift_id, ctx, 1),
         {:ok, _} <-
           Engine.act(
             [
               key(:enter),
               await(@sell_confirm_confirm_hook),
               hold(@sell_confirm_confirm_hook, @sell_confirm_steady_ms, within: @sell_confirm_steady_timeout_ms),
               retry_until(all_of([@sell_popup_hook, not_hook(@sell_confirm_confirm_hook)]), [key(:enter)],
                 every: @sell_confirm_retry_ms,
                 tries: @sell_confirm_tries,
                 retry_if: @sell_confirm_confirm_hook
               )
             ],
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

  defp select_sell_gift(gift_id, ctx, attempt) do
    with :ok <- find_and_click_gift(@sell_popup, gift_id, ctx) do
      cond do
        Engine.check_within(not_hook(@sell_nothing_selected_hook), @sell_select_check_ms) ->
          :ok

        attempt >= @sell_select_tries ->
          {:error, {:not_selected, gift_id}}

        true ->
          Ctx.log(ctx, :info, "shop sell: #{gift_id} click didn't select it, rescanning (#{attempt}/#{@sell_select_tries})")
          select_sell_gift(gift_id, ctx, attempt + 1)
      end
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
        FailureShot.record("shop_uptie_#{gift_id}", ctx)
        err
    end
  end

  defp open_uptie_popup(ctx) do
    if Engine.check(:shop_uptie_popup),
      do: {:ok, :already_open},
      else: Engine.act([retry_until(:shop_uptie_popup, [click(:shop_uptie, settle_ms: 100)], every: 1_500, tries: 3)], ctx)
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
      key(:enter)
    ]

    level =
      case Engine.act(steps, ctx) do
        {:ok, _} ->
          2

        {:error, _} ->
          Ctx.log(ctx, :info, "shop uptie: +2 isn't selected, confirming at +1")
          Engine.act([key(:enter)], ctx)
          1
      end

    await_commit(level, ctx)
  end

  defp try_commit(level, ctx) do
    Engine.act([click(:"shop_uptie_popup_commit_uptie_#{level}"), key(:enter)], ctx)
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
         {:ok, before} <- settled_shelf_scan(ctx),
         {:ok, _} <-
           Engine.act(
             [
               retry_until(:shop_keyword_refresh_popup, [click(:shop_keyword_refresh)], every: 1_500, tries: 3),
               click(affinity_hook),
               click(:shop_keyword_refresh_popup_confirm),
               await(not_hook(:shop_keyword_refresh_popup))
             ],
             ctx
           ) do
      forget_shelf(ctx)
      forget_slot_purchases(ctx)
      await_new_shelf(before, ctx)
      :ok
    else
      true -> {:error, :keyword_refresh_disabled}
      {:error, _} = err -> err
    end
  end

  defp fuse_affinity_hook("none"), do: Map.fetch!(@affinity_hooks, "burn")
  defp fuse_affinity_hook(affinity), do: Map.get(@affinity_hooks, affinity)

  defp affinity_hook(affinity) do
    case Map.fetch(@affinity_hooks, affinity) do
      {:ok, hook} -> {:ok, hook}
      :error -> {:error, {:unknown_affinity, affinity}}
    end
  end

  defp find_and_click_gift(popup, gift_id, ctx) do
    case click_visible_gift(popup, gift_id, ctx) do
      :not_visible -> seek_gift(popup, gift_id, ctx)
      result -> result
    end
  end

  defp seek_gift(@sell_popup, gift_id, ctx) do
    with {first, last} <- Map.get(RunMemory.get(ctx, @sell_gift_passes_key, %{}), gift_id),
         at when is_integer(at) <- RunMemory.get(ctx, @sell_popup_pass_key, nil),
         :not_visible <- step_toward_gift(gift_id, at, at |> max(first) |> min(last), ctx) do
      sweep_for_gift(@sell_popup, gift_id, ctx)
    else
      nil -> sweep_for_gift(@sell_popup, gift_id, ctx)
      result -> result
    end
  end

  defp seek_gift(popup, gift_id, ctx), do: sweep_for_gift(popup, gift_id, ctx)

  defp step_toward_gift(_gift_id, at, at, _ctx), do: :not_visible

  defp step_toward_gift(gift_id, at, target, ctx) do
    {scroll_step, next} = if target > at, do: {scroll_down(@sell_scroll_clicks), at + 1}, else: {scroll_up(@sell_scroll_clicks), at - 1}

    with moved when moved != :unmoved <- scroll_and_settle(@sell_inventory_hook, scroll_step, ctx),
         RunMemory.put(ctx, @sell_popup_pass_key, next),
         :not_visible <- click_visible_gift(@sell_popup, gift_id, ctx) do
      step_toward_gift(gift_id, next, target, ctx)
    else
      :unmoved -> :not_visible
      result -> result
    end
  end

  defp sweep_for_gift(popup, gift_id, ctx) do
    scroll_popup_to_top(popup, ctx, 0)
    scan_down_and_click(popup, gift_id, ctx, 0)
  end

  defp note_popup_pass(@sell_popup, pass, ctx), do: RunMemory.put(ctx, @sell_popup_pass_key, pass)
  defp note_popup_pass(_popup, _pass, _ctx), do: :ok

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
        with false <- popup_at_bottom?(popup),
             moved when moved != :unmoved <- scroll_and_settle(popup.inventory, scroll_down(@sell_scroll_clicks), ctx) do
          note_popup_pass(popup, pass + 1, ctx)
          scan_down_and_click(popup, gift_id, ctx, pass + 1)
        else
          _ -> {:error, {:not_in_popup, gift_id}}
        end

      result ->
        result
    end
  end

  defp scroll_popup_to_top(_popup, _ctx, pass) when pass >= @max_sell_scroll_passes, do: :ok

  defp scroll_popup_to_top(popup, ctx, pass) do
    checks = Engine.check_all([popup.top, popup.bottom, popup.track])

    if checks[popup.top] or not (checks[popup.bottom] or checks[popup.track]) or
         scroll_and_settle(popup.inventory, scroll_up(@scroll_to_top_clicks), ctx) == :unmoved do
      note_popup_pass(popup, 0, ctx)
    else
      scroll_popup_to_top(popup, ctx, pass + 1)
    end
  end

  defp scroll_popup_to_bottom(_popup, _ctx, pass) when pass >= @max_sell_scroll_passes, do: :ok

  defp scroll_popup_to_bottom(popup, ctx, pass) do
    if popup_at_bottom?(popup) or
         scroll_and_settle(popup.inventory, scroll_down(@scroll_to_top_clicks), ctx) == :unmoved do
      :ok
    else
      scroll_popup_to_bottom(popup, ctx, pass + 1)
    end
  end

  defp scroll_and_settle(inventory_hook, scroll_step, ctx) do
    with {:ok, _} <- Engine.act([move_to(inventory_hook)], ctx),
         {:ok, %{} = hook} <- HookRegistry.find(inventory_hook),
         {:ok, before} <- Capture.grab_frame(),
         {:ok, _} <- Engine.act([scroll_step], ctx) do
      deadline = System.monotonic_time(:millisecond) + @sell_scroll_settle_ms
      await_scroll_settled(hook.scan_region || hook.region, before, nil, deadline)
    end
  end

  defp await_scroll_settled(region, before, previous, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      if previous == nil, do: :unmoved, else: :moved
    else
      Mouse.dwell(@scroll_poll_ms)

      case Capture.grab_frame() do
        {:ok, frame} ->
          cond do
            previous == nil and same_region?(frame, before, region) -> await_scroll_settled(region, before, nil, deadline)
            previous != nil and same_region?(frame, previous, region) ->
              if same_region?(frame, before, region), do: :unmoved, else: :moved
            true -> await_scroll_settled(region, before, frame, deadline)
          end

        {:error, _} ->
          await_scroll_settled(region, before, previous, deadline)
      end
    end
  end

  defp same_region?(a, b, region) do
    {c0, c1, c2, _} = Evision.mean(Evision.absdiff(Frame.crop(a.mat, region), Frame.crop(b.mat, region)))
    max(c0, max(c1, c2)) < @scroll_still_threshold
  end

  defp popup_at_bottom?(popup) do
    checks = Engine.check_all([popup.top, popup.bottom, popup.track])
    checks[popup.bottom] or not (checks[popup.top] or checks[popup.track])
  end

  def detect_and_update_cost(ctx), do: detect_and_update_cost(@cost_read_tries, nil, ctx)

  defp detect_and_update_cost(tries_left, previous, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         read = NumberScanner.read(frame),
         Ctx.log(ctx, :info, "cost: try #{@cost_read_tries - tries_left + 1}/#{@cost_read_tries} #{inspect(read)}"),
         {:ok, ^previous} <- read do
      Ctx.log(ctx, :info, "cost: read #{previous}")
      RunMemory.put_cost(ctx, previous)
    else
      result when tries_left > 1 ->
        Mouse.dwell(@cost_read_every_ms)
        next = with {:ok, cost} <- result, do: cost, else: (_ -> nil)
        detect_and_update_cost(tries_left - 1, next, ctx)

      other ->
        Ctx.log(ctx, :error, "cost: read failed after #{@cost_read_tries} tries (#{inspect(other)})")
        if StarlightBot.Data.authoring?(), do: save_cost_failure_frame(ctx)
        :ok
    end
  end

  defp save_cost_failure_frame(ctx) do
    with {:ok, frame} <- Capture.grab_frame() do
      dir = StarlightBot.Data.screenshots_dir()
      File.mkdir_p!(dir)
      path = Path.join(dir, "cost_read_failed_#{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d_%H-%M-%S")}.png")
      if Evision.imwrite(path, frame.mat), do: Ctx.log(ctx, :info, "cost: saved screenshot #{path}")
    end
  end
end
