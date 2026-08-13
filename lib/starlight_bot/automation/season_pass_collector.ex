defmodule StarlightBot.Automation.SeasonPassCollector do
  alias StarlightBot.Ctx
  alias StarlightBot.Input.Mouse
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{Capture, Matcher}

  @xp_hook :season_pass_mission_tab_xp_available
  @alert_hook :season_pass_mission_tab_alert
  @claim_delay_ms 2_000
  @max_alert_tries 2

  @spec collect(Ctx.t()) :: :ok
  def collect(ctx) do
    claim_visible_xp(ctx)
    follow_alerts(ctx, @max_alert_tries)
  end

  defp follow_alerts(_ctx, 0), do: :ok

  defp follow_alerts(ctx, tries_left) do
    case grab_rects(@alert_hook) do
      [rect | _] ->
        Ctx.log(ctx, :info, "season_pass_collector: following alert (#{tries_left} left)")
        click_rect(rect, ctx)
        claim_visible_xp(ctx)
        follow_alerts(ctx, tries_left - 1)

      [] ->
        :ok
    end
  end

  defp claim_visible_xp(ctx) do
    rects = grab_rects(@xp_hook)
    if rects != [], do: Ctx.log(ctx, :info, "season_pass_collector: claiming #{length(rects)} xp item(s)")

    Enum.each(rects, fn rect ->
      click_rect(rect, ctx)
      Process.sleep(@claim_delay_ms)
    end)
  end

  defp grab_rects(hook) do
    case Capture.grab_frame() do
      {:ok, frame} -> Matcher.find_all(frame, hook)
      {:error, _} -> []
    end
  end

  defp click_rect({x, y, w, h}, ctx) do
    case Runner.to_screen_point({x + div(w, 2), y + div(h, 2)}) do
      {:ok, {sx, sy}} -> Mouse.visual_click(sx, sy)
      {:error, reason} -> Ctx.log(ctx, :error, "season_pass_collector: click failed: #{inspect(reason)}")
    end
  end
end
