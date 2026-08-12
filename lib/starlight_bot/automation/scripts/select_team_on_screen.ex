defmodule StarlightBot.Automation.Scripts.SelectTeamOnScreen do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.Scripts.SelectTeam
  alias StarlightBot.Ctx
  alias StarlightBot.Teams

  @front_line_size 7
  @backup_size 5

  def run(team_id, ctx \\ Ctx.new()) when is_integer(team_id) do
    with {:ok, team} <- fetch_team(team_id, ctx),
         {:ok, checks} <- check_selectors(ctx) do
      apply_team(team, checks, ctx)
    end
  end

  defp fetch_team(team_id, ctx) do
    case Teams.get_team(team_id) do
      nil ->
        Ctx.log(ctx, :error, "team #{team_id} not found")
        {:error, :team_not_found}

      team ->
        {:ok, team}
    end
  end

  defp check_selectors(ctx) do
    checks = Engine.check_all([:team_selector, :team_selector_tall, :team_selector_gone, :clear_selection])

    if checks.team_selector or checks.team_selector_tall or checks.team_selector_gone do
      {:ok, checks}
    else
      Ctx.log(ctx, :error, "no team selector on screen — wrong screen")
      {:error, :wrong_screen}
    end
  end

  defp apply_team(team, checks, ctx) do
    can_choose_team = checks.team_selector or checks.team_selector_tall
    can_choose_order = checks.clear_selection

    with :ok <- maybe_select_team(can_choose_team, team, ctx),
         :ok <- maybe_select_order(can_choose_order, team, ctx) do
      {:ok, %{team: can_choose_team, order: can_choose_order}}
    end
  end

  defp maybe_select_team(false, _team, ctx) do
    Ctx.log(ctx, :info, "team selector not present — skipping team choice")
    :ok
  end

  defp maybe_select_team(true, %{hook: hook}, ctx) when is_binary(hook) and hook != "" do
    case SelectTeam.select_hook(String.to_existing_atom(hook), ctx) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  rescue
    ArgumentError ->
      Ctx.log(ctx, :error, "unrecognized team hook #{inspect(hook)}")
      {:error, :unknown_team_hook}
  end

  defp maybe_select_team(true, _team, ctx) do
    Ctx.log(ctx, :error, "team has no hook configured")
    {:error, :team_missing_hook}
  end

  defp maybe_select_order(false, _team, ctx) do
    Ctx.log(ctx, :info, "order selection not available on this screen — skipping")
    :ok
  end

  defp maybe_select_order(true, %{sinner_order: []}, ctx) do
    Ctx.log(ctx, :info, "team has no sinner order configured — skipping")
    :ok
  end

  defp maybe_select_order(true, %{sinner_order: order}, ctx) do
    case Engine.act(order_steps(order), ctx) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp order_steps(order) do
    {front, rest} = Enum.split(order, @front_line_size)
    backup = Enum.take(rest, @backup_size)

    [click(:clear_selection)] ++
      Enum.map(front, &click(sinner_hook(&1, :selected))) ++
      Enum.map(backup, &click(sinner_hook(&1, :backup)))
  end

  defp sinner_hook(sinner, kind), do: :"sinner_#{kind}_#{String.replace(sinner, "_", "")}"
end
