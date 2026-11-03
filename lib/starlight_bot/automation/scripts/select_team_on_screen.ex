defmodule StarlightBot.Automation.Scripts.SelectTeamOnScreen do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RunMemory}
  alias StarlightBot.Ctx
  alias StarlightBot.{BattlePlans, Plans, Teams}
  alias StarlightBot.BattlePlans.Resolver

  @max_sweep_scrolls 14
  @scroll_clicks 8
  @hefty_scroll_clicks @scroll_clicks * 2
  @scroll_settle_ms 400
  @click_settle_ms 100
  @list_ready_timeout_ms 2_000
  @scroll_down_available :team_selector_scroll_down_available
  @scroll_up_available %{
    team_selector: :team_selector_short_scroll_up_available,
    team_selector_tall: :team_selector_tall_scroll_up_available
  }

  def run(team_id, venue, floor, ctx \\ Ctx.new()) when is_integer(team_id) do
    with {:ok, team} <- fetch_team(team_id, ctx),
         {:ok, checks} <- check_selectors(ctx) do
      apply_team(team, lineup_sinners(team, venue, floor, ctx), checks, ctx)
    end
  end

  def prepare_team(team, hook, ctx) do
    with {:ok, _} <- Engine.act([click(hook, settle_ms: @click_settle_ms), sleep(@click_settle_ms)], ctx),
         {:ok, checks} <- check_selectors(ctx) do
      maybe_select_order(checks.clear_selection or checks.sinner_count_0, first_lineup_sinners(team, ctx), ctx)
    end
  end

  defp first_lineup_sinners(team, ctx) do
    data =
      case team.battle_plan_id && Plans.get(:battle_plans, team.battle_plan_id) do
        %{data: data} -> data
        _ -> nil
      end

    case data |> BattlePlans.lineups() |> List.first() do
      %{"name" => name, "sinners" => sinners} ->
        Ctx.log(ctx, :info, "first lineup: #{name}")
        sinners

      nil ->
        Ctx.log(ctx, :error, "battle plan has no lineups")
        []
    end
  end

  defp lineup_sinners(team, venue, floor, ctx) do
    data =
      case team.battle_plan_id && Plans.get(:battle_plans, team.battle_plan_id) do
        %{data: data} -> data
        _ -> nil
      end

    case Resolver.lineup_for(data, venue, floor) do
      %{"name" => name, "sinners" => sinners} ->
        Ctx.log(ctx, :info, "lineup for #{BattlePlans.venue_label(venue)} F#{floor}: #{name}")
        sinners

      nil ->
        Ctx.log(ctx, :error, "battle plan has no lineup for #{BattlePlans.venue_label(venue)} F#{floor}")
        []
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

  defp apply_team(team, sinners, checks, ctx) do
    can_choose_team = checks.team_selector or checks.team_selector_tall
    can_choose_order = checks.clear_selection or checks.sinner_count_0

    with :ok <- maybe_select_team(can_choose_team, team, ctx),
         :ok <- maybe_select_order(can_choose_order, sinners, ctx) do
      {:ok, %{team: can_choose_team, order: can_choose_order}}
    end
  end

  defp maybe_select_team(false, _team, ctx) do
    Ctx.log(ctx, :info, "team selector not present — skipping team choice")
    :ok
  end

  defp maybe_select_team(true, team, ctx) do
    case run_hook(team, ctx) do
      nil ->
        Ctx.log(ctx, :error, "team has no hook configured")
        {:error, :team_missing_hook}

      hook ->
        select_team_hook(hook, ctx)
    end
  end

  defp select_team_hook(hook, ctx) do
    case select_hook(String.to_existing_atom(hook), ctx) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  rescue
    ArgumentError ->
      Ctx.log(ctx, :error, "unrecognized team hook #{inspect(hook)}")
      {:error, :unknown_team_hook}
  end

  defp run_hook(%{id: id} = team, ctx) do
    case RunMemory.team(ctx) do
      %{id: ^id, hook: hook} -> Teams.pick_hook(team, hook)
      _ -> Teams.pick_hook(team, nil)
    end
  end

  defp maybe_select_order(false, _order, ctx) do
    Ctx.log(ctx, :info, "order selection not available on this screen — skipping")
    :ok
  end

  defp maybe_select_order(true, [], ctx) do
    Ctx.log(ctx, :info, "lineup has no sinners — skipping")
    :ok
  end

  defp maybe_select_order(true, order, ctx) do
    Engine.act([move_to(:clear_selection)], ctx)
    formation = formation(order)

    case order_mismatches(formation) do
      [] ->
        Ctx.log(ctx, :ok, "sinner order already set — nothing to do")
        RunMemory.put_formation(ctx, BattlePlans.formation(order))
        :ok

      mismatches ->
        Ctx.log(ctx, :info, "sinner order needs clearing + reselecting:")
        Enum.each(mismatches, &Ctx.log(ctx, :info, "  #{&1}"))

        case Engine.act(order_steps(formation, ctx), ctx) do
          {:ok, _} ->
            RunMemory.put_formation(ctx, BattlePlans.formation(order))
            :ok

          {:error, _} = err ->
            err
        end
    end
  end

  defp order_mismatches(%{front: front, backup: backup}) do
    placed = MapSet.new(front ++ backup)
    unplaced = Enum.reject(Teams.all_sinners(), &(&1 in placed))

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

  defp order_steps(%{front: front, backup: backup}, ctx) do
    clear_steps(ctx) ++
      Enum.map(front, &click(sinner_hook(&1, :selected), duration_mult: 1.1)) ++
      Enum.map(backup, &click(sinner_hook(&1, :backup), duration_mult: 1.1))
  end

  defp formation(order), do: order |> alive_order() |> BattlePlans.formation()

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
      confirm_enter(any_of([:clear_selection_confirm, :clear_selection_confirm_2]), steady: 400) ++ [sleep(500)]
    end
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

      with true <- find_team(hook, selector, ctx),
           {:ok, _} <- Engine.act([click(hook, settle_ms: @click_settle_ms), sleep(@click_settle_ms)], ctx) do
        Ctx.log(ctx, :ok, "selected #{hook}")
        {:ok, hook}
      else
        false ->
          Ctx.log(ctx, :error, "#{hook} not found after sweeping the whole list — falling back to top team")
          select_top_team(ctx, top_team)

        {:error, reason} ->
          Ctx.log(ctx, :error, "#{hook} click failed: #{inspect(reason)} — falling back to top team")
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

  defp find_team(hook, selector, ctx) do
    Engine.check_within(any_of([hook, @scroll_down_available, scroll_available_hook(selector, :up)]), @list_ready_timeout_ms)

    Engine.check(hook) or
      (Engine.check(@scroll_down_available) and scroll_and_check(hook, selector, :down, @hefty_scroll_clicks, ctx)) or
      sweep(hook, selector, :up, ctx) or
      sweep(hook, selector, :down, ctx)
  end

  defp sweep(hook, selector, direction, ctx, scrolls \\ 0) do
    cond do
      scrolls >= @max_sweep_scrolls ->
        Ctx.log(ctx, :info, "team selector: #{scrolls} scrolls #{direction} without reaching the end")
        false

      not Engine.check(scroll_available_hook(selector, direction)) ->
        Ctx.log(ctx, :info, "team selector: reached the #{if direction == :up, do: "top", else: "bottom"} after #{scrolls} scroll(s)")
        false

      scroll_and_check(hook, selector, direction, @scroll_clicks, ctx) ->
        true

      true ->
        sweep(hook, selector, direction, ctx, scrolls + 1)
    end
  end

  defp scroll_available_hook(_selector, :down), do: @scroll_down_available
  defp scroll_available_hook(selector, :up), do: Map.fetch!(@scroll_up_available, selector)

  defp scroll_and_check(hook, selector, direction, clicks, ctx) do
    scroll = if direction == :up, do: scroll_up(clicks), else: scroll_down(clicks)
    Engine.act([move_to(selector), scroll, sleep(@scroll_settle_ms)], ctx)
    Engine.check(hook)
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
