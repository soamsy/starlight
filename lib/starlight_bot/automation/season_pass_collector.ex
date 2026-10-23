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
    Engine.act(steps(), ctx)
    :ok
  end

  def steps do
    [
      call(__MODULE__, :claim_visible_xp),
      call(__MODULE__, :follow_alerts, [@max_alert_tries]),
      branch([
        {@claim_all_available_hook,
         [
           log(:info, "season_pass_collector: claim all available"),
           attempt(claim_all_steps(), else: {__MODULE__, :claim_all_failed, []})
         ]}
      ])
    ]
  end

  def follow_alerts(0, _frame, _ctx), do: {:ok, nil}

  def follow_alerts(tries_left, _frame, ctx) do
    case grab_rects(@alert_hook) do
      [{x, y, w, h} | _] ->
        Ctx.log(ctx, :info, "season_pass_collector: following alert (#{tries_left} left)")
        click_rect({x - 10, y + 20, w, h}, ctx)
        {:steps, [sleep(@alert_delay_ms), call(__MODULE__, :claim_visible_xp), call(__MODULE__, :follow_alerts, [tries_left - 1])]}

      [] ->
        {:ok, nil}
    end
  end

  def claim_visible_xp(_frame, ctx) do
    case grab_rects(@xp_hook) do
      [] ->
        {:ok, nil}

      rects ->
        Ctx.log(ctx, :info, "season_pass_collector: claiming #{length(rects)} xp item(s)")
        {:steps, Enum.flat_map(rects, &[call(__MODULE__, :click_xp, [&1]), sleep(@claim_delay_ms)])}
    end
  end

  def click_xp(rect, _frame, ctx) do
    click_rect(rect, ctx)
    {:ok, nil}
  end

  def claim_all_failed({:error, reason}, _frame, ctx) do
    Ctx.log(ctx, :error, "season_pass_collector: claim all failed: #{inspect(reason)}")
    {:ok, nil}
  end

  defp claim_all_steps do
    [retry_until_gone(:season_pass_missions_tab, [click(:season_pass_battle_pass)])] ++
      confirm(:season_pass_claim_all, timeout: @claim_all_confirm_timeout) ++
      confirm(:season_pass_claim_all_confirm, timeout: @claim_all_confirm_timeout)
  end

  defp grab_rects(hook) do
    case Capture.grab_frame() do
      {:ok, frame} -> Matcher.find_all(frame, hook)
      {:error, _} -> []
    end
  end

  defp click_rect({x, y, w, h}, ctx) do
    case Runner.to_screen_point({x + div(w, 2), y + div(h, 2)}) do
      {:ok, {sx, sy}} -> Mouse.click(sx, sy)
      {:error, reason} -> Ctx.log(ctx, :error, "season_pass_collector: click failed: #{inspect(reason)}")
    end
  end
end
