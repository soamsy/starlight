defmodule StarlightBot.Automation.Scripts.SelectTeam do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx

  @teams ~w(
    burn bleed tremor rupture sinking poise charge wrath lust sloth
    gluttony gloom pride envy slash pierce blunt
  )a

  @max_scroll_attempts 5
  @scroll_to_bottom_clicks 30
  @scroll_up_clicks 8
  @scroll_settle_ms 500

  def run(team_type, ctx \\ Ctx.new())

  def run(team_type, ctx) when team_type in @teams do
    case Engine.localize() do
      {:ok, :team_select} ->
        select_hook(team_hook(team_type), ctx)

      {:ok, other} ->
        Ctx.log(ctx, :error, "not on :team_select (currently #{other}) — doing nothing")
        {:error, {:wrong_screen, other}}

      :unknown ->
        Ctx.log(ctx, :error, "screen not recognized — doing nothing")
        {:error, {:wrong_screen, :unknown}}
    end
  end

  def run(team_type, ctx) do
    Ctx.log(ctx, :error, "unknown team_type #{inspect(team_type)} (expected one of #{inspect(@teams)})")
    {:error, {:invalid_team_type, team_type}}
  end

  def select_hook(hook, ctx \\ Ctx.new()) when is_atom(hook) do
    selected_hook = :"#{hook}_selected"

    if Engine.check(selected_hook) do
      Ctx.log(ctx, :ok, "#{selected_hook} already selected — nothing to do")
      {:ok, selected_hook}
    else
      {selector, top_team} = selector_pair()
      Ctx.log(ctx, :info, "looking for #{hook} in team selector (#{selector})")

      case Engine.act(find_and_select_steps(hook, selector), ctx) do
        {:ok, _} ->
          Ctx.log(ctx, :ok, "selected #{hook}")
          {:ok, hook}

        {:error, reason} ->
          Ctx.log(ctx, :error, "#{hook} not found: #{inspect(reason)} — falling back to top team")
          select_top_team(ctx, top_team)
      end
    end
  end

  defp team_hook(team_type), do: :"team_#{team_type}"

  defp selector_pair do
    if Engine.check(:team_selector_tall) do
      {:team_selector_tall, :team_selector_tall_top_team}
    else
      {:team_selector, :team_selector_top_team}
    end
  end

  defp find_and_select_steps(hook, selector) do
    [
      branch([
        {hook, [click(hook)]},
        {:default,
         [
           move_to(selector),
           scroll_down(@scroll_to_bottom_clicks),
           sleep(@scroll_settle_ms),
           retry_until(
             hook,
             [move_to(selector), scroll_up(@scroll_up_clicks)],
             every: @scroll_settle_ms,
             tries: @max_scroll_attempts
           ),
           click(hook),
         ]},
      ])
    ]
  end

  defp select_top_team(ctx, top_team) do
    Process.sleep(@scroll_settle_ms)

    case Engine.act([click(top_team)], ctx) do
      {:ok, _} ->
        Ctx.log(ctx, :ok, "selected top team")
        {:ok, top_team}

      {:error, reason} = err ->
        Ctx.log(ctx, :error, "fallback top-team click failed: #{inspect(reason)}")
        err
    end
  end
end
