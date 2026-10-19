defmodule StarlightBot.Automation.GiftPicker do
  alias StarlightBot.Automation.{RewardHelpers, RunMemory}
  alias StarlightBot.{Ctx, EgoGifts, GiftPlans}
  alias StarlightBot.Vision.{Capture, EgoGiftDetector, HookRegistry, Matcher}

  @slot_w 350
  @slot_h 250
  @same_slot_fraction 0.8
  @min_item_area_px 550

  def pick(scan_hook, count, tier_hooks, fallback_hook, ctx, pick_delay_ms \\ 0) do
    gifts_by_id = Map.new(EgoGifts.list_gifts(), &{&1.id, &1})
    {frame, detections} = scan(scan_hook, ctx)
    named = slots(detections)
    badge_slots = badge_slots(named, tier_badges(frame, tier_hooks))
    ranked = rank(named ++ badge_slots, wanted_names(gifts_by_id, ctx), RunMemory.ego_gifts(ctx), gifts_by_id)
    chosen = Enum.take(ranked, count)

    Ctx.log(
      ctx,
      :info,
      "gift picker: #{length(named)} gift(s) found in #{scan_hook}, #{length(badge_slots)} more from tier badges, picking " <>
        if(chosen == [], do: "none", else: Enum.map_join(chosen, ", ", & &1.gift_name))
    )

    with {:ok, clicked} <- click_slots(chosen, pick_delay_ms, ctx) do
      fallback(count - length(clicked), clicked, tier_hooks, fallback_hook, pick_delay_ms, ctx)
    end
  end

  def slots(detections) do
    detections
    |> Enum.sort_by(&(-(&1[:classifier_confidence] || &1[:detector_confidence] || 0)))
    |> Enum.reduce([], fn item, kept ->
      if Enum.any?(kept, &same_slot?(&1, item)), do: kept, else: kept ++ [to_slot(item)]
    end)
    |> Enum.sort_by(&elem(&1.center, 0))
  end

  def badge_slots(named_slots, badges) do
    Enum.reduce(badges, [], fn {tier, rect}, kept ->
      point = center(rect)

      if Enum.any?(named_slots ++ kept, &inside?(point, &1.rect)),
        do: kept,
        else: kept ++ [badge_slot(tier, point)]
    end)
  end

  defp badge_slot(tier, {cx, cy}) do
    rect = {round(cx - @slot_w / 2), round(cy - @slot_h / 2), @slot_w, @slot_h}
    %{gift_id: nil, gift_name: "unnamed tier #{tier} gift", tier: tier, center: {cx, cy}, rect: rect}
  end

  defp inside?({px, py}, {x, y, w, h}), do: px >= x and px <= x + w and py >= y and py <= y + h

  defp tier_badges(nil, _tier_hooks), do: []

  defp tier_badges(frame, tier_hooks) do
    for hook <- tier_hooks, tier = hook_tier(hook), rect <- Matcher.find_all(frame, hook), do: {tier, rect}
  end

  defp hook_tier(hook) do
    case Regex.run(~r/_tier_(\d+)$/, Atom.to_string(hook)) do
      [_, tier] -> String.to_integer(tier)
      nil -> nil
    end
  end

  def rank(slots, wanted_names, owned, gifts_by_id) do
    wanted_rank = wanted_names |> Enum.with_index() |> Map.new()

    Enum.sort_by(slots, fn slot ->
      gift = gifts_by_id[slot.gift_id]
      tier = (gift && gift.tier) || Map.get(slot, :tier) || 0

      cond do
        Map.has_key?(wanted_rank, slot.gift_name) and not Map.has_key?(owned, slot.gift_id) -> {-tier, 0, wanted_rank[slot.gift_name]}
        not Map.has_key?(owned, slot.gift_id) -> {-tier, 1, 0}
        true -> {-tier, 2, 0}
      end
    end)
  end

  defp scan(scan_hook, ctx) do
    with {:ok, %{} = hook} <- HookRegistry.find(scan_hook),
         region when not is_nil(region) <- hook.scan_region || hook.region,
         {:ok, frame} <- Capture.grab_frame(),
         {:ok, results} <- EgoGiftDetector.detect(frame.mat, region) do
      detections =
        results
        |> Enum.filter(&(&1.w * &1.h >= @min_item_area_px))
        |> Enum.reject(&is_nil(&1.gift_id))

      {frame, detections}
    else
      other ->
        Ctx.log(ctx, :error, "gift picker: couldn't scan #{scan_hook} (#{inspect(other)}), using tier badges only")
        {nil, []}
    end
  end

  defp same_slot?(%{center: {sx, sy}}, item) do
    {cx, cy} = center(item)
    abs(cx - sx) < @slot_w / 2 * @same_slot_fraction and abs(cy - sy) < @slot_h / 2 * @same_slot_fraction
  end

  defp to_slot(item) do
    {cx, cy} = center(item)
    rect = {round(cx - @slot_w / 2), round(cy - @slot_h / 2), @slot_w, @slot_h}
    %{gift_id: item.gift_id, gift_name: item.gift_name, center: {cx, cy}, rect: rect}
  end

  defp center(%{x: x, y: y, w: w, h: h}), do: {x + w / 2, y + h / 2}
  defp center({x, y, w, h}), do: {x + w / 2, y + h / 2}

  defp wanted_names(gifts_by_id, ctx) do
    with %{} = data <- RunMemory.gift_strategy(ctx),
         plan = GiftPlans.normalize(data),
         %{} = workflow <- GiftPlans.workflow_for_floor(plan, RunMemory.floor(ctx)) do
      Enum.uniq(GiftPlans.keep_gifts(plan, workflow) ++ GiftPlans.derived_protected(plan, workflow, Map.values(gifts_by_id)))
    else
      _ -> []
    end
  end

  defp click_slots(slots, pick_delay_ms, ctx) do
    Enum.reduce_while(slots, {:ok, []}, fn %{center: {cx, cy}, rect: rect} = slot, {:ok, clicked} ->
      case RewardHelpers.click_rect({round(cx), round(cy), 0, 0}, ctx) do
        {:ok, _} ->
          Ctx.log(ctx, :ok, "gift picker: clicked #{slot.gift_name}")
          Process.sleep(pick_delay_ms)
          {:cont, {:ok, clicked ++ [rect]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp fallback(remaining, clicked, _tier_hooks, _fallback_hook, _pick_delay_ms, _ctx) when remaining <= 0, do: {:ok, clicked}

  defp fallback(remaining, clicked, tier_hooks, fallback_hook, pick_delay_ms, ctx) do
    Ctx.log(ctx, :info, "gift picker: #{remaining} pick(s) left, falling back to tier badges")

    case RewardHelpers.select_best_available_gift(tier_hooks, fallback_hook, ctx, exclude: clicked) do
      {:ok, {:clicked, rect}} ->
        Process.sleep(pick_delay_ms)
        fallback(remaining - 1, clicked ++ [rect], tier_hooks, fallback_hook, pick_delay_ms, ctx)

      {:ok, :fallback} ->
        Process.sleep(pick_delay_ms)
        fallback(remaining - 1, clicked, tier_hooks, fallback_hook, pick_delay_ms, ctx)

      {:error, _} = err ->
        err
    end
  end
end
