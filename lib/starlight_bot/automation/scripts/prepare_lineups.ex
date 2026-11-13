defmodule StarlightBot.Automation.Scripts.PrepareLineups do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.Scripts.SelectTeamOnScreen
  alias StarlightBot.{Ctx, Teams}

  @top_clicks 16
  @scroll_up_available %{
    team_selector: :team_selector_short_scroll_up_available,
    team_selector_tall: :team_selector_tall_scroll_up_available
  }
  @scroll_clicks 8
  @max_scrolls 14
  @scroll_down_available :team_selector_scroll_down_available
  @scroll_settle_ms 600

  def program, do: [log(:info, "Localizing…"), locate_screen(then: {__MODULE__, :located, []})]

  def located({:ok, :team_select} = outcome, frame, ctx), do: at_team_select(outcome, frame, ctx)

  def located({:ok, screen}, _frame, _ctx) do
    steps = [goto(screen, :lux_exp), goto(:lux_exp, :team_select)]
    {:steps, [capture(steps, then: {__MODULE__, :at_team_select, []})]}
  end

  def located(:unknown, _frame, ctx) do
    Ctx.log(ctx, :error, "screen not recognized")
    {:error, :unknown_screen}
  end

  def at_team_select({:ok, _screen}, _frame, _ctx) do
    steps = [invoke(__MODULE__, :sweep), key(:esc)]
    {:steps, [capture(steps, then: {__MODULE__, :swept, []})]}
  end

  def at_team_select(error, _frame, _ctx), do: error

  def sweep(ctx) do
    pending = ctx |> pending_by_hook() |> Map.new(fn {hook, [team | _]} -> {hook, [team]} end)
    Ctx.log(ctx, :info, "preparing #{pending |> Map.values() |> List.flatten() |> length()} team(s) in one pass")
    selector = if Engine.check(:team_selector_tall), do: :team_selector_tall, else: :team_selector
    scroll_to_top(selector, 0, ctx)
    scan(pending, selector, 0, ctx)
  end

  def scroll_to_top(selector, scrolls, ctx) do
    if scrolls < @max_scrolls and Engine.check(Map.fetch!(@scroll_up_available, selector)) do
      Engine.act([move_to(selector), scroll_up(@top_clicks), sleep(@scroll_settle_ms)], ctx)
      scroll_to_top(selector, scrolls + 1, ctx)
    end
  end

  defp scan(pending, _selector, _scrolls, ctx) when map_size(pending) == 0 do
    Ctx.log(ctx, :ok, "all teams prepared")
    {:ok, :done}
  end

  defp scan(pending, selector, scrolls, ctx) do
    visible = Engine.check_all(Map.keys(pending))
    pending = Enum.reduce(pending, pending, fn {hook, teams}, acc -> handle(visible[hook], hook, teams, acc, ctx) end)

    cond do
      map_size(pending) == 0 -> scan(pending, selector, scrolls, ctx)
      scrolls >= @max_scrolls or not Engine.check(@scroll_down_available) -> unfound(pending, ctx)
      true ->
        Engine.act([move_to(selector), scroll_down(@scroll_clicks), sleep(@scroll_settle_ms)], ctx)
        scan(pending, selector, scrolls + 1, ctx)
    end
  end

  defp handle(true, hook, teams, pending, ctx) do
    Enum.each(teams, fn team ->
      Ctx.log(ctx, :info, "team #{team.name}")
      SelectTeamOnScreen.prepare_team(team, hook, ctx)
    end)

    Map.delete(pending, hook)
  end

  defp handle(_missing, _hook, _teams, pending, _ctx), do: pending

  defp unfound(pending, ctx) do
    names = pending |> Map.values() |> List.flatten() |> Enum.map_join(", ", & &1.name)
    Ctx.log(ctx, :error, "not found in the team selector: #{names}")
    {:error, :teams_not_found}
  end

  defp pending_by_hook(ctx) do
    grouped =
      Teams.list_teams()
      |> Enum.flat_map(fn team ->
        case team |> Teams.pick_hook(nil) |> existing_atom() do
          nil -> []
          hook -> [{hook, team}]
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.each(grouped, fn
      {hook, [first | skipped]} when skipped != [] ->
        Ctx.log(ctx, :error, "#{hook} is shared by #{Enum.map_join([first | skipped], ", ", & &1.name)}; preparing only #{first.name}")

      _ ->
        :ok
    end)

    grouped
  end

  defp existing_atom(nil), do: nil

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  def swept({:ok, _}, _frame, _ctx), do: {:steps, [locate_screen(then: {__MODULE__, :home, []})]}
  def swept(error, _frame, _ctx), do: error

  def home({:ok, screen}, _frame, _ctx), do: {:steps, [goto(screen, :home, then: {__MODULE__, :done, []})]}
  def home(:unknown, _frame, _ctx), do: {:error, :unknown_screen}

  def done(outcome, _frame, _ctx), do: {:steps, [result(outcome)]}
end
