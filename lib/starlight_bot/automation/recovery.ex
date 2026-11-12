defmodule StarlightBot.Automation.Recovery do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.{Ctx, Scheduler}
  alias StarlightBot.Navigation.{Catalog, Navigator, Runner}

  @escape_hook :safe_corner
  @escape_click_sleep_ms 300
  @max_escape_hops 3
  @server_error_close_from_error 3
  @fresh_check_ms 1
  @maintenance_cancel_wait_ms 10_000
  @maintenance_click_gap_ms 1_000
  @maintenance_hold_hours "4"
  @maintenance_screens [:scheduled_maintenance, :cannot_operate_game]
  @goto_recoverable [:verification_failed, :retry_exhausted, :timeout]

  def steps(keep, errors, then),
    do: close_server_error(errors) ++ [locate_screen(then: {__MODULE__, :located, [keep, @max_escape_hops, then]})]

  def located(_keep, _hops_left, _then, {:ok, screen}, _frame, ctx) when screen in @maintenance_screens do
    Ctx.log(ctx, :error, "#{screen} popup, dismissing it and canceling the run (Limbus will close)")

    {:steps,
     [
       attempt([click(:scheduled_maintenance)], else: []),
       sleep(@maintenance_click_gap_ms),
       attempt([click(:cannot_operate_game)], else: []),
       call(__MODULE__, :cancel_run),
       sleep(@maintenance_cancel_wait_ms)
     ]}
  end

  def located(keep, hops_left, then, {:ok, screen}, _frame, ctx), do: escape(screen, keep, hops_left, then, ctx)
  def located(_keep, _hops_left, then, :unknown, _frame, ctx), do: {:steps, fallback(then, ctx)}

  def keeps_all?(_screen), do: true

  def goto_delivered(to, then, attempts_left, {:error, {kind, _}} = err, _frame, ctx)
      when attempts_left > 0 and kind in @goto_recoverable do
    Ctx.log(ctx, :error, "goto #{to} failed (#{inspect(err)}), relocalizing (#{attempts_left} attempt(s) left)")
    {:steps, steps({__MODULE__, :keeps_all?}, 0, {__MODULE__, :goto_relocated, [to, then, attempts_left, err]})}
  end

  def goto_delivered(_to, then, _attempts_left, result, _frame, _ctx), do: deliver(then, result)

  def goto_relocated(to, then, _attempts_left, _err, {:ok, to}, _frame, _ctx), do: deliver(then, {:ok, to})
  def goto_relocated(to, then, attempts_left, _err, {:ok, screen}, _frame, _ctx), do: {:steps, [{:goto, screen, to, then, attempts_left - 1}]}
  def goto_relocated(_to, then, _attempts_left, err, :unknown, _frame, _ctx), do: deliver(then, err)

  def cancel_run(_frame, _ctx) do
    Navigator.cancel()
    Scheduler.hold(@maintenance_hold_hours)
    {:ok, nil}
  end

  def escaped(keep, hops_left, then, _result, _frame, _ctx),
    do: {:steps, [locate_screen(then: {__MODULE__, :located, [keep, hops_left - 1, then]})]}

  defp escape(screen, _keep, 0, then, _ctx), do: deliver(then, {:ok, screen})

  defp escape(screen, {keep_mod, keep_fun}, hops_left, then, ctx) do
    case if(apply(keep_mod, keep_fun, [screen]), do: nil, else: Catalog.escape_transition(screen)) do
      nil ->
        deliver(then, {:ok, screen})

      transition ->
        Ctx.log(ctx, :info, "#{screen} has an escape route to #{transition.to} — leaving before resuming")
        {:steps, [capture(Runner.plan_program([transition]), then: {__MODULE__, :escaped, [{keep_mod, keep_fun}, hops_left, then]})]}
    end
  end

  defp close_server_error(errors) when errors >= @server_error_close_from_error do
    [
      branch(
        [
          {:server_error_close,
           [
             log(:info, "server error popup up, closing it"),
             attempt([click(:server_error_close), sleep(500)], else: []),
             attempt([click(:potential_server_popup_confirm), sleep(500)], else: [])
           ]}
        ],
        wait: @fresh_check_ms
      )
    ]
  end

  defp close_server_error(_errors), do: []

  def nudge_steps do
    escape_steps = [
      click(@escape_hook), sleep(@escape_click_sleep_ms),
      key(:esc), sleep(@escape_click_sleep_ms),
      click(@escape_hook), sleep(@escape_click_sleep_ms),
      branch([
        {:random_confirm, [click(:random_confirm)]},
        {:random_confirm_2, [click(:random_confirm_2)]},
      ]),
    ]

    [attempt(escape_steps, else: [])]
  end

  defp fallback(then, ctx) do
    Ctx.log(ctx, :error, "still unrecognized — trying #{@escape_hook}/esc/#{@escape_hook} to find a pickoff point")
    nudge_steps() ++ [locate_screen(then: then)]
  end

  defp deliver({mod, fun, args}, result), do: {:steps, [call(mod, fun, args ++ [result])]}
end
