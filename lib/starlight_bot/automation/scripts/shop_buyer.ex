defmodule StarlightBot.Automation.Scripts.ShopBuyer do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RewardHelpers, RunMemory}
  alias StarlightBot.Ctx
  alias StarlightBot.EgoGifts
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{Capture, EgoGiftDetector, HookRegistry, NumberScanner}

  @max_purchases 5
  @min_item_area_px 300
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

  def run(ctx) do
    detect_and_update_cost(ctx)
    Process.sleep(1000) # TODO: remove. this is unnecessary and just for debugging

    case check_inventory(ctx) do
      {:ok, _} ->
        case fetch_gift_strategy(ctx) do
          {:ok, gift_strategy} ->
            buy_pass(buy_on_sight_index(gift_strategy), @max_purchases, ctx)

          {:error, :no_gift_strategy} ->
            Ctx.log(ctx, :error, "shop buyer: no gift strategy in run memory — buying nothing")
            leave(ctx)
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
         {:ok, hook} <- find_inventory_hook(ctx) do
      record_inventory_items(frame, hook.scan_region || hook.region, ctx)
    else
      {:error, reason} -> Ctx.log(ctx, :error, "shop sell inventory scan: #{inspect(reason)}")
    end
  end

  defp find_inventory_hook(ctx) do
    case HookRegistry.find(@sell_inventory_hook) do
      {:ok, %{region: nil, scan_region: nil}} ->
        Ctx.log(ctx, :error, "shop sell inventory scan: #{@sell_inventory_hook} hook has no region configured")
        {:error, :no_region}

      {:ok, hook} ->
        {:ok, hook}

      {:error, :not_found} ->
        Ctx.log(ctx, :error, "shop sell inventory scan: #{@sell_inventory_hook} hook not found")
        {:error, :not_found}
    end
  end

  defp record_inventory_items(frame, region, ctx) do
    case EgoGiftDetector.detect(frame.mat, region) do
      {:ok, results} ->
        results
        |> Enum.filter(&item_large_enough?/1)
        |> Enum.each(&record_inventory_item(&1, ctx))

      {:error, reason} ->
        Ctx.log(ctx, :error, "shop sell inventory scan: classify failed: #{inspect(reason)}")
    end
  end

  defp record_inventory_item(%{gift_id: nil}, _ctx), do: :ok

  defp record_inventory_item(%{gift_id: gift_id, gift_name: gift_name}, ctx) do
    RunMemory.add_ego_gift(ctx, gift_id, gift_name)
  end

  defp log_inventory(ctx) do
    names = RunMemory.ego_gifts(ctx) |> Map.values() |> Enum.sort()
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

  defp buy_pass(_buy_on_sight, 0, ctx), do: leave(ctx)

  defp buy_pass(buy_on_sight, remaining, ctx) do
    case scan_and_buy(buy_on_sight, remaining, ctx) do
      {:ok, 0} ->
        leave(ctx)

      {:ok, remaining_after} ->
        maybe_refresh_and_continue(buy_on_sight, remaining_after, ctx)

      {:stop, _remaining_after} ->
        leave(ctx)

      {:error, _} = err ->
        err
    end
  end

  defp maybe_refresh_and_continue(buy_on_sight, remaining, ctx) do
    if Engine.check(:shop_refresh_disabled) do
      Ctx.log(ctx, :info, "shop buyer: refresh disabled, leaving with #{@max_purchases - remaining} bought")
      leave(ctx)
    else
      case Engine.run_action(:shop, :refresh_shelf, ctx) do
        {:ok, _} -> buy_pass_after_refresh(buy_on_sight, remaining, ctx)
        {:error, _} = err -> err
      end
    end
  end

  defp buy_pass_after_refresh(buy_on_sight, remaining, ctx) do
    detect_and_update_cost(ctx)

    case scan_and_buy(buy_on_sight, remaining, ctx) do
      {:error, _} = err -> err
      _other -> leave(ctx)
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

  defp leave(ctx) do
    case Engine.localize() do
      {:ok, screen} when screen in [:shop, :shop_super] -> Engine.goto(screen, :dungeon_graph, ctx)
      {:ok, screen} -> {:ok, screen}
      :unknown -> {:error, :unknown_screen}
    end
  end
end
