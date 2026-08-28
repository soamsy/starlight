defmodule StarlightBot.Automation.SeasonPassCollector do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx
  alias StarlightBot.Input.Mouse
  alias StarlightBot.Navigation.Runner
  alias StarlightBot.Vision.{Capture, Matcher}

  @xp_hook :season_pass_mission_tab_xp_available
  @alert_hook :season_pass_mission_tab_alert
  @claim_all_available_hook :season_pass_claim_all_available
  @claim_delay_ms 1_500
  @alert_delay_ms 1_000
  @max_alert_tries 2
  @claim_all_confirm_timeout 3_000

  @spec collect(Ctx.t()) :: :ok
  def collect(ctx) do
    claim_visible_xp(ctx)
    follow_alerts(ctx, @max_alert_tries)
    maybe_claim_all(ctx)
  end

  defp follow_alerts(_ctx, 0), do: :ok

  defp follow_alerts(ctx, tries_left) do
    case grab_rects(@alert_hook) do
      [rect | _] ->
        Ctx.log(ctx, :info, "season_pass_collector: following alert (#{tries_left} left)")
        click_rect(rect, ctx)
        Process.sleep(@alert_delay_ms)
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

  defp maybe_claim_all(ctx) do
    if Engine.check(@claim_all_available_hook) do
      Ctx.log(ctx, :info, "season_pass_collector: claim all available")
      claim_all(ctx)
    else
      :ok
    end
  end

  defp claim_all(ctx) do
    with {:ok, _} <- Engine.goto(:season_pass_missions_tab, :season_pass, ctx),
         {:ok, _} <-
           Engine.act(
             [
               click(:season_pass_claim_all),
               await(:season_pass_claim_all_confirm, timeout: @claim_all_confirm_timeout),
               click(:season_pass_claim_all_confirm)
             ],
             ctx
           ),
         {:ok, _} <- Engine.goto(:season_pass, :season_pass_missions_tab, ctx) do
      :ok
    else
      {:error, reason} ->
        Ctx.log(ctx, :error, "season_pass_collector: claim all failed: #{inspect(reason)}")
        :ok
    end
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
