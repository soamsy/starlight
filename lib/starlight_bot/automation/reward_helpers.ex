defmodule StarlightBot.Automation.RewardHelpers do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RunMemory}
  alias StarlightBot.Ctx
  alias StarlightBot.Input.Mouse
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{Capture, EgoGiftDetector, HookRegistry, Matcher}

  @default_appear_timeout 5_000
  @same_slot_tolerance_px 30
  @min_ego_gift_item_area_px 550

  def dismiss_ego_gift_get_step, do: custom(fn _frame, ctx -> dismiss_ego_gift_get(ctx) end)

  def record_ego_gift_items_step, do: custom(fn frame, ctx -> record_ego_gift_items(frame, ctx) end)

  defp record_ego_gift_items(frame, ctx) do
    case frame || elem(Capture.grab_frame(), 1) do
      nil ->
        Ctx.log(ctx, :error, "ego gift scan: no frame available")
        {:ok, nil}

      frame ->
        scan_ego_gift_region(frame, ctx)
        {:ok, frame}
    end
  end

  defp scan_ego_gift_region(frame, ctx) do
    case HookRegistry.find(:ego_gift_get_item) do
      {:ok, %{region: nil, scan_region: nil}} ->
        Ctx.log(ctx, :error, "ego gift scan: ego_gift_get_item hook has no region configured")

      {:ok, hook} ->
        classify_and_record(frame, hook.scan_region || hook.region, ctx)

      {:error, :not_found} ->
        Ctx.log(ctx, :error, "ego gift scan: ego_gift_get_item hook not found")
    end
  end

  defp classify_and_record(frame, region, ctx) do
    case EgoGiftDetector.detect(frame.mat, region) do
      {:ok, []} ->
        Ctx.log(ctx, :info, "ego gift scan: nothing detected in #{inspect(region)}")

      {:ok, results} ->
        candidates = Enum.filter(results, &item_large_enough?/1)

        Ctx.log(
          ctx,
          :info,
          "ego gift scan: #{length(results)} detection(s), #{length(candidates)} above #{@min_ego_gift_item_area_px}px"
        )

        Enum.each(candidates, &record_ego_gift_result(&1, ctx))

      {:error, reason} ->
        Ctx.log(ctx, :error, "ego gift classify failed for #{inspect(region)}: #{inspect(reason)}")
    end
  end

  defp item_large_enough?(%{w: w, h: h}), do: w * h >= @min_ego_gift_item_area_px

  defp record_ego_gift_result(%{gift_id: nil} = result, ctx) do
    Ctx.log(ctx, :info, "ego gift scan: unclassified item (top guess: #{top_guess(result)})")
  end

  defp record_ego_gift_result(%{gift_id: gift_id, gift_name: gift_name, classifier_confidence: conf}, ctx) do
    already_known? = Map.has_key?(RunMemory.ego_gifts(ctx), gift_id)
    RunMemory.add_ego_gift(ctx, gift_id, gift_name)

    if already_known? do
      Ctx.log(ctx, :info, "ego gift scan: saw #{gift_name} again (#{pct(conf)})")
    else
      Ctx.log(ctx, :ok, "ego gift inventory: added #{gift_name} (#{gift_id}, #{pct(conf)})")
    end
  end

  defp top_guess(%{topk: [top | _]}), do: "#{top.name} #{pct(top.confidence)}"
  defp top_guess(_), do: "none"

  defp pct(nil), do: "—"
  defp pct(v), do: "#{round(v * 100)}%"

  def select_best_available_gift(tier_hooks, fallback_hook, ctx, opts \\ []) do
    case find_and_click_first(tier_hooks, ctx, opts) do
      {:ok, {:clicked, _rect}} = ok ->
        ok

      {:ok, :none} ->
        Ctx.log(ctx, :info, "no tier badge visible — falling back to #{fallback_hook}")

        case Engine.act([click(fallback_hook)], ctx) do
          {:ok, _} -> {:ok, :fallback}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  def find_and_click_first(hooks, ctx, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, [])

    case Capture.grab_frame() do
      {:ok, frame} ->
        case find_best_tier_rect(frame, hooks, exclude) do
          {:ok, rect} ->
            Ctx.log(ctx, :info, "selecting best available gift via rect match")

            case click_rect(rect, ctx) do
              {:ok, _} -> {:ok, {:clicked, rect}}
              {:error, _} = err -> err
            end

          :none ->
            {:ok, :none}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def dismiss_ego_gift_get(ctx, opts \\ []) do
    appear_timeout = Keyword.get(opts, :appear_timeout, @default_appear_timeout)

    case Engine.act([await(:ego_gift_get, timeout: appear_timeout)], ctx) do
      {:ok, _} ->
        dismiss_visible_ego_gift_get(ctx)

      {:error, {:timeout, :ego_gift_get}} ->
        Ctx.log(ctx, :info, "ego_gift_get did not appear — assuming already dismissed")
        {:ok, nil}

      {:error, _} = err ->
        err
    end
  end

  defp dismiss_visible_ego_gift_get(ctx) do
    case Engine.act([retry_until(not_hook(:ego_gift_get), [key(:space), click(:ego_gift_get_confirm)], every: 700, tries: 5)], ctx) do
      {:ok, _} = ok ->
        Process.sleep(500)
        ok

      {:error, _} ->
        Ctx.log(ctx, :info, "ego_gift_get: space didn't dismiss it — clicking confirm instead")

        Engine.act(
          [retry_until(not_hook(:ego_gift_get), [click(:ego_gift_get_confirm)], every: 700, tries: 5), sleep(500)],
          ctx
        )
    end
  end

  defp find_best_tier_rect(frame, tier_hooks, exclude) do
    Enum.find_value(tier_hooks, :none, fn hook ->
      frame
      |> Matcher.find_all(hook)
      |> Enum.reject(&already_clicked?(&1, exclude))
      |> case do
        [rect | _] -> {:ok, rect}
        [] -> nil
      end
    end)
  end

  defp already_clicked?({x, y, w, h}, exclude) do
    cx = x + div(w, 2)
    cy = y + div(h, 2)

    Enum.any?(exclude, fn {ex, ey, ew, eh} ->
      ecx = ex + div(ew, 2)
      ecy = ey + div(eh, 2)
      abs(cx - ecx) <= @same_slot_tolerance_px and abs(cy - ecy) <= @same_slot_tolerance_px
    end)
  end

  def click_rect({x, y, w, h}, ctx) do
    case Runner.to_screen_point({x + div(w, 2), y + div(h, 2)}) do
      {:ok, {sx, sy}} ->
        Mouse.visual_click(sx, sy)
        {:ok, nil}

      {:error, reason} ->
        Ctx.log(ctx, :error, "gift rect click failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
