defmodule StarlightBot.Automation.Scripts.SelectTeamOnScreen do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx
  alias StarlightBot.Teams

  @front_line_size 7
  @backup_size 5
  @all_sinners ~w(
    yi_sang faust don_quixote ryoshu meursault hong_lu
    heathcliff ishmael rodion sinclair outis gregor
  )

  @max_scroll_attempts 5
  @scroll_to_bottom_clicks 30
  @scroll_up_clicks 8
  @scroll_settle_ms 500

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
    case select_hook(String.to_existing_atom(hook), ctx) do
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
    Engine.act([move_to(:clear_selection)], ctx)
    case order_mismatches(order) do
      [] ->
        Ctx.log(ctx, :ok, "sinner order already set — nothing to do")
        :ok

      mismatches ->
        Ctx.log(ctx, :info, "sinner order needs clearing + reselecting:")
        Enum.each(mismatches, &Ctx.log(ctx, :info, "  #{&1}"))

        case Engine.act(order_steps(order, ctx), ctx) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  defp order_mismatches(order) do
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

    front_mismatches =
      front
      |> Enum.reject(&checks[sinner_hook(&1, :selected)])
      |> Enum.map(&"#{&1}: expected in front line, not detected as selected")

    backup_mismatches =
      backup
      |> Enum.reject(&checks[sinner_hook(&1, :backup)])
      |> Enum.map(&"#{&1}: expected in backup, not detected as backup")

    unplaced_mismatches =
      unplaced
      |> Enum.filter(&(checks[sinner_hook(&1, :selected)] or checks[sinner_hook(&1, :backup)]))
      |> Enum.map(fn sinner ->
        where = if checks[sinner_hook(sinner, :selected)], do: "front line", else: "backup"
        "#{sinner}: expected unplaced, detected in #{where}"
      end)

    front_mismatches ++ backup_mismatches ++ unplaced_mismatches
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
      [click(:clear_selection)] ++
      confirm_either(:clear_selection_confirm, :clear_selection_confirm_2) ++
      [sleep(400)]
    end
  end

  defp confirm_either(hook_a, hook_b) do
    [
      await_any([hook_a, hook_b]),
      branch([{hook_a, [click(hook_a)]}, {hook_b, [click(hook_b)]}])
    ]
  end

  defp sinner_hook(sinner, kind), do: :"sinner_#{kind}_#{String.replace(sinner, "_", "")}"

  defp select_hook(hook, ctx) when is_atom(hook) do
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
