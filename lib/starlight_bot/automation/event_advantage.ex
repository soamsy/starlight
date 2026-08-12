defmodule StarlightBot.Automation.EventAdvantage do
  alias StarlightBot.Ctx
  alias StarlightBot.Input.Mouse
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{Capture, Matcher}

  @tiers_best_to_worst [
    :event_skill_very_high,
    :event_skill_high,
    :event_skill_average,
    :event_skill_low,
    :event_skill_very_low
  ]

  @spec select_best_sinner(term, Ctx.t()) :: {:ok, term} | {:error, term}
  def select_best_sinner(_last_frame, ctx) do
    case Capture.grab_frame() do
      {:ok, frame} ->
        case best_match(frame) do
          {:ok, tier, {x, y, w, h}} ->
            click_center(x, y, w, h, ctx)
            Ctx.log(ctx, :ok, "event_advantage: picked #{tier}")
            {:ok, nil}

          :not_found ->
            Ctx.log(ctx, :info, "event_advantage: no skill tier visible yet")
            {:ok, nil}
        end

      {:error, reason} ->
        Ctx.log(ctx, :info, "event_advantage: screenshot failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  defp best_match(frame) do
    Enum.find_value(@tiers_best_to_worst, :not_found, fn tier ->
      case frame |> Matcher.find_all(tier) |> Enum.sort_by(fn {x, _y, _w, _h} -> -x end) do
        [rect | _] -> {:ok, tier, rect}
        [] -> nil
      end
    end)
  end

  defp click_center(x, y, w, h, ctx) do
    case Runner.to_screen_point({x + div(w, 2), y + div(h, 2)}) do
      {:ok, {sx, sy}} -> Mouse.visual_click(sx, sy)
      {:error, reason} -> Ctx.log(ctx, :error, "event_advantage: click failed: #{inspect(reason)}")
    end
  end
end
