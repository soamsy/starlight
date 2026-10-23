defmodule StarlightBot.Automation.Recovery do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.{Catalog, Runner}

  @escape_hook :safe_corner
  @escape_click_sleep_ms 300
  @max_escape_hops 3

  def steps(keep, then), do: [locate_screen(then: {__MODULE__, :located, [keep, @max_escape_hops, then]})]

  def located(keep, hops_left, then, {:ok, screen}, _frame, ctx), do: escape(screen, keep, hops_left, then, ctx)
  def located(_keep, _hops_left, then, :unknown, _frame, ctx), do: {:steps, fallback(then, ctx)}

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

  defp fallback(then, ctx) do
    Ctx.log(ctx, :error, "still unrecognized — trying #{@escape_hook}/esc/#{@escape_hook} to find a pickoff point")

    escape_steps = [
      click(@escape_hook), sleep(@escape_click_sleep_ms),
      key(:esc), sleep(@escape_click_sleep_ms),
      click(@escape_hook), sleep(@escape_click_sleep_ms)
    ]

    [attempt(escape_steps, else: []), locate_screen(then: then)]
  end

  defp deliver({mod, fun, args}, result), do: {:steps, [call(mod, fun, args ++ [result])]}
end
