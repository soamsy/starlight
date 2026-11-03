defmodule StarlightBot.Automation.Scripts.GiftSearchPicker do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RewardHelpers, RunMemory}
  alias StarlightBot.{Ctx, EgoGifts, GiftPlans}
  alias StarlightBot.Vision.{Capture, EgoGiftDetector, HookRegistry}

  @scan_hook :gift_search_scan_area
  @selected_area_hook :gift_search_selected_area
  @verify_retries 2
  @clicked_key :gift_search_clicked
  @none_selected_hook :gift_search_select_0_3
  @selected_timeout_ms 1_500
  @selected_poll_ms 200
  @leave_timeout_ms 3_000
  @scroll_clicks 4
  @scroll_settle_ms 400
  @tab_load_timeout_ms 1_500
  @tab_retry_timeout_ms 700
  @tab_poll_ms 50
  @tab_click_retries 3
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

    {:steps, [call(__MODULE__, :search_tabs, [tabs, clicked(ctx), @verify_retries])]}
  end

  def search_tabs([], picked, retries, _frame, ctx) do
    cond do
      MapSet.size(picked) == 0 ->
        Ctx.log(ctx, :info, "gift search: none of the planned gifts were found, refusing")
        {:steps, [goto(:gift_search, :theme_pack)]}

      retries > 0 ->
        {:steps, [premove(:gift_search_select), call(__MODULE__, :verify_selected, [picked, retries])]}

      true ->
        {:steps, select_steps(picked)}
    end
  end

  def search_tabs([{tab, gifts} | rest], picked, retries, _frame, _ctx) do
    wanted = MapSet.new(gifts, & &1.id)

    if MapSet.subset?(wanted, picked) do
      {:steps, [call(__MODULE__, :search_tabs, [rest, picked, retries])]}
    else
      load = call(__MODULE__, :load_tab, [tab, wanted, picked, rest, retries, @tab_click_retries])
      {:steps, [attempt([click(:"gift_search_#{tab}")], else: []), load]}
    end
  end

  def load_tab(tab, wanted, picked, rest, retries, clicks_left, _frame, ctx) do
    tab_ids = for gift <- EgoGifts.list_gifts(), GiftPlans.gift_search_tab(gift) == tab, into: MapSet.new(), do: gift.id

    timeout_ms = if clicks_left == @tab_click_retries, do: @tab_load_timeout_ms, else: @tab_retry_timeout_ms

    with {:ok, {x, y, w, h}} <- hook_region(@scan_hook, ctx),
         {:ok, status} <- await_tab_items(tab_ids, {x, y, div(w, 2), div(h, 2)}, System.monotonic_time(:millisecond) + timeout_ms) do
      cond do
        status == :loaded ->
          scan_pass(tab, wanted, picked, MapSet.new(), 0, rest, retries, nil, ctx)

        clicks_left > 0 ->
          Ctx.log(ctx, :info, "gift search: no #{tab} gift showed up within #{timeout_ms}ms, clicking the tab again (#{clicks_left} left)")
          reload = call(__MODULE__, :load_tab, [tab, wanted, picked, rest, retries, clicks_left - 1])
          {:steps, [attempt([click(:"gift_search_#{tab}")], else: []), reload]}

        true ->
          Ctx.log(ctx, :info, "gift search: no #{tab} gift showed up after #{@tab_click_retries} more clicks, scanning anyway")
          scan_pass(tab, wanted, picked, MapSet.new(), 0, rest, retries, nil, ctx)
      end
    else
      {:error, reason} ->
        Ctx.log(ctx, :error, "gift search: #{tab} scan failed: #{inspect(reason)}")
        {:steps, [call(__MODULE__, :search_tabs, [rest, picked, retries])]}
    end
  end

  defp await_tab_items(tab_ids, region, deadline) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, items} <- EgoGiftDetector.detect(frame.mat, region) do
      cond do
        Enum.any?(items, &MapSet.member?(tab_ids, &1.gift_id)) ->
          {:ok, :loaded}

        System.monotonic_time(:millisecond) >= deadline ->
          {:ok, :timeout}

        true ->
          Process.sleep(@tab_poll_ms)
          await_tab_items(tab_ids, region, deadline)
      end
    end
  end

  def scan_pass(tab, _wanted, picked, _seen, pass, rest, retries, _frame, ctx) when pass >= @max_scroll_passes do
    Ctx.log(ctx, :error, "gift search: #{tab} tab hit #{@max_scroll_passes} scroll passes")
    {:steps, [call(__MODULE__, :search_tabs, [rest, picked, retries])]}
  end

  def scan_pass(tab, wanted, picked, seen, pass, rest, retries, _frame, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, region} <- hook_region(@scan_hook, ctx),
         {:ok, items} <- EgoGiftDetector.detect(frame.mat, region) do
      items = Enum.filter(items, &(&1.gift_id && &1.w * &1.h >= @min_item_area_px))
      picked = Enum.reduce(items, picked, &click_if_wanted(&1, wanted, &2, ctx))
      visible = MapSet.new(items, & &1.gift_id)

      cond do
        MapSet.subset?(wanted, picked) ->
          {:steps, [call(__MODULE__, :search_tabs, [rest, picked, retries])]}

        pass > 0 and MapSet.subset?(visible, seen) ->
          Ctx.log(ctx, :info, "gift search: reached the end of the #{tab} tab")
          {:steps, [call(__MODULE__, :search_tabs, [rest, picked, retries])]}

        true ->
          next = call(__MODULE__, :scan_pass, [tab, wanted, picked, MapSet.union(seen, visible), pass + 1, rest, retries])
          {:steps, [attempt([move_to(@scan_hook), scroll_down(@scroll_clicks), sleep(@scroll_settle_ms)], else: []), next]}
      end
    else
      {:error, reason} ->
        Ctx.log(ctx, :error, "gift search: #{tab} scan failed: #{inspect(reason)}")
        {:steps, [call(__MODULE__, :search_tabs, [rest, picked, retries])]}
    end
  end

  def verify_selected(picked, retries, _frame, ctx) do
    case missing_selected(picked, System.monotonic_time(:millisecond) + @selected_timeout_ms, ctx) do
      {:ok, missing} ->
        if MapSet.size(missing) == 0 do
          {:steps, select_steps(picked)}
        else
          gifts = EgoGifts.list_gifts()
          missing_names = for gift <- gifts, MapSet.member?(missing, gift.id), do: gift.name
          tabs = GiftPlans.gift_search_tabs(missing_names, Map.new(gifts, &{&1.name, &1}))
          Ctx.log(ctx, :info, "gift search: #{Enum.join(missing_names, ", ")} missing from #{@selected_area_hook}, searching again (retry #{@verify_retries - retries + 1}/#{@verify_retries})")
          RunMemory.update(ctx, @clicked_key, [], &Enum.reject(&1, fn id -> MapSet.member?(missing, id) end))
          {:steps, [call(__MODULE__, :search_tabs, [tabs, MapSet.difference(picked, missing), retries - 1])]}
        end

      {:error, reason} ->
        Ctx.log(ctx, :error, "gift search: couldn't check #{@selected_area_hook}: #{inspect(reason)}, selecting anyway")
        {:steps, select_steps(picked)}
    end
  end

  defp missing_selected(picked, deadline, ctx) do
    with {:ok, frame} <- Capture.grab_frame(),
         {:ok, region} <- hook_region(@selected_area_hook, ctx),
         {:ok, items} <- EgoGiftDetector.detect(frame.mat, region) do
      missing = MapSet.difference(picked, MapSet.new(items, & &1.gift_id))

      if MapSet.size(missing) == 0 or System.monotonic_time(:millisecond) >= deadline do
        {:ok, missing}
      else
        Process.sleep(@selected_poll_ms)
        missing_selected(picked, deadline, ctx)
      end
    end
  end

  defp select_steps(picked) do
    refuse = [
      log(:error, "gift search: clicked #{MapSet.size(picked)} gift(s) but the screen still shows 0/3 selected, refusing"),
      goto(:gift_search, :theme_pack)
    ]

    confirm = [
      log(:ok, "gift search: selected #{MapSet.size(picked)} gift(s), confirming"),
      key(:enter)
    ]

    [branch([{not_hook(@none_selected_hook), confirm ++ confirm_enter(:gift_search_select_confirm) ++ [dismiss_ego_gift_get()]}, default: refuse], wait: @selected_timeout_ms)]
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

  defp hook_region(hook, ctx) do
    case HookRegistry.find(hook) do
      {:ok, %{scan_region: region}} when not is_nil(region) -> {:ok, region}
      {:ok, %{region: region}} when not is_nil(region) -> {:ok, region}
      _ ->
        Ctx.log(ctx, :error, "gift search: #{hook} hook missing or has no region")
        {:error, :no_scan_region}
    end
  end
end
