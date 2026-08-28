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

  def run(ctx) do
    detect_and_update_cost(ctx)
    Process.sleep(1000) # TODO: remove. this is unnecessary and just for debugging

    case RunMemory.team_affinity(ctx) do
      nil ->
        Ctx.log(ctx, :error, "shop buyer: no team affinity in run memory — buying nothing")
        leave(ctx)

      affinity ->
        buy_pass(affinity, @max_purchases, ctx)
    end
  end

  defp buy_pass(_affinity, 0, ctx), do: leave(ctx)

  defp buy_pass(affinity, remaining, ctx) do
    case scan_and_buy(affinity, remaining, ctx) do
      {:ok, 0} ->
        leave(ctx)

      {:ok, remaining_after} ->
        maybe_refresh_and_continue(affinity, remaining_after, ctx)

      {:stop, _remaining_after} ->
        leave(ctx)

      {:error, _} = err ->
        err
    end
  end

  defp maybe_refresh_and_continue(affinity, remaining, ctx) do
    if Engine.check(:shop_refresh_disabled) do
      Ctx.log(ctx, :info, "shop buyer: refresh disabled, leaving with #{@max_purchases - remaining} bought")
      leave(ctx)
    else
      case Engine.run_action(:shop, :refresh_shelf, ctx) do
        {:ok, _} -> buy_pass_after_refresh(affinity, remaining, ctx)
        {:error, _} = err -> err
      end
    end
  end

  defp buy_pass_after_refresh(affinity, remaining, ctx) do
    case scan_and_buy(affinity, remaining, ctx) do
      {:error, _} = err -> err
      _other -> leave(ctx)
    end
  end

  defp scan_and_buy(affinity, remaining, ctx) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        candidates = matching_candidates(frame, affinity, ctx)
        Ctx.log(ctx, :info, "shop buyer: #{length(candidates)} item(s) match #{affinity} and aren't owned")
        buy_each(candidates, remaining, ctx)

      {:error, reason} ->
        {:error, reason}
    end
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

  defp matching_candidates(frame, affinity, ctx) do
    shelf_hooks()
    |> Enum.flat_map(&detect_row(frame, &1, affinity, ctx))
  end

  defp shelf_hooks do
    if Engine.check(:shop_super), do: @super_shelf_hooks, else: @normal_shelf_hooks
  end

  defp detect_row(frame, hook_name, affinity, ctx) do
    case HookRegistry.find(hook_name) do
      {:ok, %{region: nil, scan_region: nil}} ->
        Ctx.log(ctx, :error, "shop buyer: #{hook_name} hook has no region configured")
        []

      {:ok, hook} ->
        detect_candidates(frame, hook.scan_region || hook.region, affinity, ctx)

      {:error, :not_found} ->
        Ctx.log(ctx, :error, "shop buyer: #{hook_name} hook not found")
        []
    end
  end

  defp detect_candidates(frame, region, affinity, ctx) do
    case EgoGiftDetector.detect(frame.mat, region) do
      {:ok, results} ->
        results
        |> Enum.filter(&item_large_enough?/1)
        |> Enum.filter(&wants_item?(&1, affinity, ctx))

      {:error, reason} ->
        Ctx.log(ctx, :error, "shop buyer: shelf classify failed: #{inspect(reason)}")
        []
    end
  end

  defp item_large_enough?(%{w: w, h: h}), do: w * h >= @min_item_area_px

  defp wants_item?(%{gift_id: nil}, _affinity, _ctx), do: false

  defp wants_item?(%{gift_id: gift_id, gift_name: gift_name}, affinity, ctx) do
    already_owned? = Map.has_key?(RunMemory.ego_gifts(ctx), gift_id)
    item_affinity = EgoGifts.affinity_for(gift_id)
    wanted? = item_affinity == affinity and not already_owned?

    Ctx.log(ctx, :info, "shop buyer: #{gift_name} (#{item_affinity || "unknown"}) — #{if wanted?, do: "want", else: "skip"}")

    wanted?
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
