defmodule StarlightBot.Automation.Scripts.RewardHelpers do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx
  alias StarlightBot.Input.Mouse
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{Capture, Matcher}

  @default_appear_timeout 5_000
  @same_slot_tolerance_px 30

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
        Engine.act(
          [retry_until(not_hook(:ego_gift_get), [key(:space)], every: 700, tries: 8), sleep(500)],
          ctx
        )

      {:error, {:timeout, :ego_gift_get}} ->
        Ctx.log(ctx, :info, "ego_gift_get did not appear — assuming already dismissed")
        {:ok, nil}

      {:error, _} = err ->
        err
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

  defp click_rect({x, y, w, h}, ctx) do
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
