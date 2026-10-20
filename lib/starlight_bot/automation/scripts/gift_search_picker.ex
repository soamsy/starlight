defmodule StarlightBot.Automation.Scripts.GiftSearchPicker do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RewardHelpers, RunMemory}
  alias StarlightBot.{Ctx, EgoGifts, GiftPlans}
  alias StarlightBot.Vision.{Capture, EgoGiftDetector, HookRegistry}

  @scan_hook :gift_search_scan_area
  @clicked_key :gift_search_clicked
  @none_selected_hook :gift_search_select_0_3
  @selected_timeout_ms 1_500
  @leave_timeout_ms 3_000
  @scroll_clicks 4
  @scroll_settle_ms 400
  @tab_settle_ms 600
  @max_scroll_passes 20
  @min_item_area_px 300

  def reset(ctx), do: RunMemory.put(ctx, @clicked_key, [])

  def run(names, ctx) do
    gifts_by_name = Map.new(EgoGifts.list_gifts(), &{&1.name, &1})
    tabs = GiftPlans.gift_search_tabs(names, gifts_by_name)
    Ctx.log(ctx, :info, "gift search: looking for " <> Enum.map_join(tabs, "; ", &tab_label/1))

    if Engine.check(@none_selected_hook) and clicked(ctx) != MapSet.new() do
      Ctx.log(ctx, :info, "gift search: screen shows 0/3 selected, forgetting #{MapSet.size(clicked(ctx))} remembered pick(s) and searching again")
      reset(ctx)
    end

    picked = Enum.reduce(tabs, clicked(ctx), fn {tab, gifts}, acc -> search_tab(tab, MapSet.new(gifts, & &1.id), acc, ctx) end)

    cond do
      MapSet.size(picked) == 0 ->
        Ctx.log(ctx, :info, "gift search: none of the planned gifts were found, refusing")
        Engine.goto(:gift_search, :theme_pack, ctx)

      match?({:error, _}, Engine.act([await(not_hook(@none_selected_hook), timeout: @selected_timeout_ms)], ctx)) ->
        Ctx.log(ctx, :error, "gift search: clicked #{MapSet.size(picked)} gift(s) but the screen still shows 0/3 selected, refusing")
        Engine.goto(:gift_search, :theme_pack, ctx)

      true ->
        n = MapSet.size(picked)
        Ctx.log(ctx, :ok, "gift search: selected #{n} gift(s), confirming")
        with {:ok, _} <- Engine.act([click(:gift_search_select, settle_ms: 50)] ++ confirm_enter(:gift_search_select_confirm), ctx) do
          dismiss_ego_gift_get(ctx)
        end
    end
  end

  defp dismiss_ego_gift_get(ctx) do
    case Engine.act([await(:ego_gift_get), RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step(leaving: :gift_search)], ctx) do
      {:ok, _} = ok ->
        Ctx.log(ctx, :ok, "gift search: dismissed ego gift get")
        if Engine.check(:ego_gift_get) do
          dismiss_ego_gift_get(ctx)
        else
          Engine.act([await(not_hook(:gift_search), timeout: @leave_timeout_ms)], ctx)
          ok
        end

      {:error, reason} ->
        Ctx.log(ctx, :info, "gift search: no ego gift get (#{inspect(reason)}), moving on")
        {:ok, nil}
    end
  end

  defp tab_label({tab, gifts}), do: "#{tab}: " <> Enum.map_join(gifts, ", ", & &1.name)

  defp clicked(ctx), do: ctx |> RunMemory.get(@clicked_key, []) |> MapSet.new()

  defp search_tab(tab, wanted, picked, ctx) do
    if MapSet.subset?(wanted, picked) do
      picked
    else
      Engine.act([click(:"gift_search_#{tab}"), sleep(@tab_settle_ms)], ctx)
      scan_pass(tab, wanted, picked, MapSet.new(), ctx, 0)
    end
  end

  defp scan_pass(tab, _wanted, picked, _seen, ctx, pass) when pass >= @max_scroll_passes do
    Ctx.log(ctx, :error, "gift search: #{tab} tab hit #{@max_scroll_passes} scroll passes")
    picked
  end

  defp scan_pass(tab, wanted, picked, seen, ctx, pass) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, region} <- scan_region(ctx),
         {:ok, items} <- EgoGiftDetector.detect(frame.mat, region, capture_tag: :gift_search) do
      items = Enum.filter(items, &(&1.gift_id && &1.w * &1.h >= @min_item_area_px))
      picked = Enum.reduce(items, picked, &click_if_wanted(&1, wanted, &2, ctx))
      visible = MapSet.new(items, & &1.gift_id)

      cond do
        MapSet.subset?(wanted, picked) ->
          picked

        pass > 0 and MapSet.subset?(visible, seen) ->
          Ctx.log(ctx, :info, "gift search: reached the end of the #{tab} tab")
          picked

        true ->
          Engine.act([move_to(@scan_hook), scroll_down(@scroll_clicks), sleep(@scroll_settle_ms)], ctx)
          scan_pass(tab, wanted, picked, MapSet.union(seen, visible), ctx, pass + 1)
      end
    else
      {:error, reason} ->
        Ctx.log(ctx, :error, "gift search: #{tab} scan failed: #{inspect(reason)}")
        picked
    end
  end

  defp click_if_wanted(item, wanted, picked, ctx) do
    if MapSet.member?(wanted, item.gift_id) and not MapSet.member?(picked, item.gift_id) do
      RewardHelpers.click_rect({round(item.x), round(item.y), round(item.w), round(item.h)}, ctx)
      RunMemory.update(ctx, @clicked_key, [], &(&1 ++ [item.gift_id]))
      Ctx.log(ctx, :ok, "gift search: clicked #{item.gift_name}")
      MapSet.put(picked, item.gift_id)
    else
      picked
    end
  end

  defp scan_region(ctx) do
    case HookRegistry.find(@scan_hook) do
      {:ok, %{scan_region: region}} when not is_nil(region) -> {:ok, region}
      {:ok, %{region: region}} when not is_nil(region) -> {:ok, region}
      _ ->
        Ctx.log(ctx, :error, "gift search: #{@scan_hook} hook missing or has no region")
        {:error, :no_scan_region}
    end
  end
end
