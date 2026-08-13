defmodule StarlightBot.Automation.Scripts.SelectTeamOnScreen do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.Scripts.SelectTeam
  alias StarlightBot.Ctx
  alias StarlightBot.Teams

  @front_line_size 7
  @backup_size 5
  @all_sinners ~w(
    yi_sang faust don_quixote ryoshu meursault hong_lu
    heathcliff ishmael rodion sinclair outis gregor
  )

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
    checks = Engine.check_all([:team_selector, :team_selector_tall, :team_selector_gone, :clear_selection, :sinner_count_0])

    if checks.team_selector or checks.team_selector_tall or checks.team_selector_gone do
      {:ok, checks}
    else
      Ctx.log(ctx, :error, "no team selector on screen — wrong screen")
      {:error, :wrong_screen}
    end
  end

  defp apply_team(team, checks, ctx) do
    can_choose_team = checks.team_selector or checks.team_selector_tall
    can_choose_order = checks.clear_selection or checks.sinner_count_0

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
    if order_already_set?(order) do
      Ctx.log(ctx, :ok, "sinner order already set — nothing to do")
      :ok
    else
      case Engine.act(order_steps(order, ctx), ctx) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp order_already_set?(order) do
    {front, backup} = front_and_backup(order)
    placed = MapSet.new(front ++ backup)
    unplaced = Enum.reject(@all_sinners, &(&1 in placed))

    checks =
      Engine.check_all(
        Enum.map(front, &sinner_hook(&1, :selected)) ++
          Enum.map(backup, &sinner_hook(&1, :backup)) ++
          Enum.map(unplaced, &sinner_hook(&1, :selected)) ++
          Enum.map(unplaced, &sinner_hook(&1, :backup))
      )

    Enum.all?(front, &checks[sinner_hook(&1, :selected)]) and
      Enum.all?(backup, &checks[sinner_hook(&1, :backup)]) and
      Enum.all?(unplaced, &(not checks[sinner_hook(&1, :selected)] and not checks[sinner_hook(&1, :backup)]))
  end

  defp order_steps(order, ctx) do
    {front, backup} = front_and_backup(order)

    clear_steps(ctx) ++
      Enum.map(front, &click(sinner_hook(&1, :selected))) ++
      Enum.map(backup, &click(sinner_hook(&1, :backup)))
  end

  defp front_and_backup(order) do
    {front, rest} = order |> alive_order() |> Enum.split(@front_line_size)
    {front, Enum.take(rest, @backup_size)}
  end

  defp alive_order(order) do
    dead = Engine.check_all(Enum.map(order, &sinner_hook(&1, :dead)))
    Enum.reject(order, &dead[sinner_hook(&1, :dead)])
  end

  defp clear_steps(ctx) do
    if Engine.check(:sinner_count_0) do
      Ctx.log(ctx, :info, "sinner_count_0 already set — skipping clear_selection")
      []
    else
      [click(:clear_selection), await(:clear_selection_confirm), click(:clear_selection_confirm), sleep(400)]
    end
  end

  defp sinner_hook(sinner, kind), do: :"sinner_#{kind}_#{String.replace(sinner, "_", "")}"
end
