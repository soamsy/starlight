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

  def run(names, ctx), do: Engine.act(steps(names), ctx)

  def steps(names), do: [call(__MODULE__, :start_search, [names])]

  def start_search(names, _frame, ctx) do
    gifts_by_name = Map.new(EgoGifts.list_gifts(), &{&1.name, &1})
    tabs = GiftPlans.gift_search_tabs(names, gifts_by_name)
    Ctx.log(ctx, :info, "gift search: looking for " <> Enum.map_join(tabs, "; ", &tab_label/1))

    if Engine.check(@none_selected_hook) and clicked(ctx) != MapSet.new() do
      Ctx.log(ctx, :info, "gift search: screen shows 0/3 selected, forgetting #{MapSet.size(clicked(ctx))} remembered pick(s) and searching again")
      reset(ctx)
    end

    {:steps, [call(__MODULE__, :search_tabs, [tabs, clicked(ctx)])]}
  end

  def search_tabs([], picked, _frame, ctx) do
    if MapSet.size(picked) == 0 do
      Ctx.log(ctx, :info, "gift search: none of the planned gifts were found, refusing")
      {:steps, [goto(:gift_search, :theme_pack)]}
    else
      refuse = [
        log(:error, "gift search: clicked #{MapSet.size(picked)} gift(s) but the screen still shows 0/3 selected, refusing"),
        goto(:gift_search, :theme_pack)
      ]

      confirm = [
        log(:ok, "gift search: selected #{MapSet.size(picked)} gift(s), confirming"),
        click(:gift_search_select, settle_ms: 50)
      ]

      {:steps, [branch([{not_hook(@none_selected_hook), confirm ++ confirm_enter(:gift_search_select_confirm) ++ [dismiss_ego_gift_get()]}, default: refuse], wait: @selected_timeout_ms)]}
    end
  end

  def search_tabs([{tab, gifts} | rest], picked, _frame, _ctx) do
    wanted = MapSet.new(gifts, & &1.id)

    if MapSet.subset?(wanted, picked) do
      {:steps, [call(__MODULE__, :search_tabs, [rest, picked])]}
    else
      scan = call(__MODULE__, :scan_pass, [tab, wanted, picked, MapSet.new(), 0, rest])
      {:steps, [attempt([click(:"gift_search_#{tab}"), sleep(@tab_settle_ms)], else: []), scan]}
    end
  end

  def scan_pass(tab, _wanted, picked, _seen, pass, rest, _frame, ctx) when pass >= @max_scroll_passes do
    Ctx.log(ctx, :error, "gift search: #{tab} tab hit #{@max_scroll_passes} scroll passes")
    {:steps, [call(__MODULE__, :search_tabs, [rest, picked])]}
  end

  def scan_pass(tab, wanted, picked, seen, pass, rest, _frame, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, region} <- scan_region(ctx),
         {:ok, items} <- EgoGiftDetector.detect(frame.mat, region, capture_tag: :gift_search) do
      items = Enum.filter(items, &(&1.gift_id && &1.w * &1.h >= @min_item_area_px))
      picked = Enum.reduce(items, picked, &click_if_wanted(&1, wanted, &2, ctx))
      visible = MapSet.new(items, & &1.gift_id)

      cond do
        MapSet.subset?(wanted, picked) ->
          {:steps, [call(__MODULE__, :search_tabs, [rest, picked])]}

        pass > 0 and MapSet.subset?(visible, seen) ->
          Ctx.log(ctx, :info, "gift search: reached the end of the #{tab} tab")
          {:steps, [call(__MODULE__, :search_tabs, [rest, picked])]}

        true ->
          next = call(__MODULE__, :scan_pass, [tab, wanted, picked, MapSet.union(seen, visible), pass + 1, rest])
          {:steps, [attempt([move_to(@scan_hook), scroll_down(@scroll_clicks), sleep(@scroll_settle_ms)], else: []), next]}
      end
    else
      {:error, reason} ->
        Ctx.log(ctx, :error, "gift search: #{tab} scan failed: #{inspect(reason)}")
        {:steps, [call(__MODULE__, :search_tabs, [rest, picked])]}
    end
  end

  defp dismiss_ego_gift_get do
    attempt(
      [
        await(:ego_gift_get),
        RewardHelpers.record_ego_gift_items_step(),
        RewardHelpers.dismiss_ego_gift_get_step(leaving: :gift_search),
        log(:ok, "gift search: dismissed ego gift get"),
        branch([
          {:ego_gift_get, [call(__MODULE__, :dismiss_again)]},
          default: [attempt([await(not_hook(:gift_search), timeout: @leave_timeout_ms)], else: [])]
        ])
      ],
      else: {__MODULE__, :no_ego_gift_get, []}
    )
  end

  def dismiss_again(_frame, _ctx), do: {:steps, [dismiss_ego_gift_get()]}

  def no_ego_gift_get({:error, reason}, _frame, ctx) do
    Ctx.log(ctx, :info, "gift search: no ego gift get (#{inspect(reason)}), moving on")
    {:ok, nil}
  end

  defp tab_label({tab, gifts}), do: "#{tab}: " <> Enum.map_join(gifts, ", ", & &1.name)

  defp clicked(ctx), do: ctx |> RunMemory.get(@clicked_key, []) |> MapSet.new()

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
