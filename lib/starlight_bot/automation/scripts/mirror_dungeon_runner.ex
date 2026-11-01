defmodule StarlightBot.Automation.Scripts.MirrorDungeonRunner do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{BattleLoop, DungeonPathPlanner, Engine, EnkephalinCharger, Recovery, RewardHelpers, RunMemory}
  alias StarlightBot.Automation.Scripts.{ClaimRewards, GiftSearchPicker, SelectTeamOnScreen, ShopRunner, ThemePackSelector}
  alias StarlightBot.Automation.SeasonPassCollector
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.Ctx
  alias StarlightBot.{DailyProgress, GiftPlans, RunnerForms, Teams}
  alias StarlightBot.Navigation.{Catalog, Runner, Screen}
  alias StarlightBot.PackPlans.Resolver
  alias StarlightBot.Navigation.Screens.Shop
  alias StarlightBot.Vision.Capture

  @max_dispatch_iterations 2_000
  @max_consecutive_errors 10
  @affinities ~w(bleed blunt burn charge pierce poise rupture sinking slash tremor)a
  @home_screens [:home, :home_drive, :home_window, :home_sinners, :home_theater, :home_extract, :home_dispense, :home_unknown]
  @door_family @home_screens ++ [:md_door, :md_door_unknown, :md_door_enter_popup, :md_door_progress]
  @enkephalin_charge_screens @home_screens ++ [:md_door, :md_door_unknown]
  @shop_popup_screens Shop.popup_screens()
  @shop_screens [:shop, :shop_super | @shop_popup_screens]
  @team_select_screens [:team_select, :team_selector, :team_selector_tall, :team_selector_gone]
  @in_dungeon_screens [
    :team_selector_md, :grace, :grace_confirm, :cabinet_ego_gifts, :gift_search, :ego_gift_get, :theme_pack, :dungeon_graph, :dungeon_graph_superposition_popup, :dungeon_graph_danger_zone_skip, :adversities,
    :event, :shop, :shop_super, :cabinet_reward, :mounting_trials, :encounter_reward, :battle_over_confirm
  ] ++ @team_select_screens ++ @shop_popup_screens
  @own_run_screens [:dungeon_graph, :event, :shop, :shop_super]
  @recovery_kept_screens @in_dungeon_screens ++ [:md_door_unknown, :md_door_enter_popup, :md_door_progress, :md_door_forfeit]
  @dungeon_graph_floor_hooks 15..1//-1 |> Enum.reject(&(&1 == 13)) |> Enum.map(&:"dungeon_graph_floor_#{&1}")
  @clear_graph_timeout_ms 8_000
  @clear_graph_poll_ms 100
  @fresh_check_ms 1
  @settle_check_ms 800
  @next_screen_wait_ms 15_000
  @cabinet_available_hooks [cabinet_ego_gift_available_3: 3, cabinet_ego_gift_available_2: 2, cabinet_ego_gift_available_1: 1]

  def program(picks, run_count, config), do: [call(__MODULE__, :start, [picks, run_count, config])]

  def start([_ | _] = picks, run_count, %{rewards: rewards} = config, _frame, ctx)
      when is_integer(run_count) and run_count >= 0 and rewards in [:none, :claim, :claim_weekly, :claim_auto] do
    with {:ok, teams} <- prepare_teams(picks, ctx) do
      {:steps, Recovery.steps(keep(), 0, {__MODULE__, :started, [teams, run_count, config, 0]})}
    end
  end

  def start(_picks, _run_count, _config, _frame, ctx) do
    Ctx.log(ctx, :error, "teams must be a non-empty list, run_count a non-negative integer, and config must include rewards (:none, :claim, :claim_weekly or :claim_auto)")
    {:error, :invalid_arguments}
  end

  def started(teams, run_count, config, _errors, {:ok, first_screen}, _frame, ctx) do
    Ctx.log(ctx, :ok, "on screen: #{first_screen}")
    cycle = activate(%{teams: teams, index: 0}, ctx)
    RunMemory.put_team(ctx, team_memory(cycle.team))
    RunMemory.put_context(ctx, :mirror_dungeon)
    RunMemory.put_floor(ctx, 1)
    RunMemory.put(ctx, :run_progress, %{current: min(1, run_count), total: run_count})
    run = %{count: run_count, run_state: %{own_run?: false}, iterations: 0, errors: 0, cycle: cycle, config: config}
    {:steps, [loop(run, nil)]}
  end

  def started(teams, run_count, config, errors, :unknown, _frame, ctx) do
    Ctx.log(ctx, :error, "screen not recognized")
    errors = errors + 1

    if errors >= @max_consecutive_errors do
      Ctx.log(ctx, :error, "mirror dungeon runner: #{errors} consecutive errors, giving up (last: :unknown_screen)")
      {:error, :unknown_screen}
    else
      Ctx.log(ctx, :error, "mirror dungeon runner: error #{errors}/#{@max_consecutive_errors} (:unknown_screen) — re-localizing and retrying")
      {:steps, Recovery.steps(keep(), errors, {__MODULE__, :started, [teams, run_count, config, errors]})}
    end
  end

  def loop(%{count: count} = run, _known_screen, _frame, _ctx) when count <= 0 do
    {:steps, season_pass_steps(run.config) ++ [locate_screen(then: {__MODULE__, :go_home, []})]}
  end

  def loop(%{iterations: iterations}, _known_screen, _frame, ctx) when iterations > @max_dispatch_iterations do
    Ctx.log(ctx, :error, "mirror dungeon runner: exceeded #{@max_dispatch_iterations} dispatch iterations without completing this run")
    {:error, :dispatch_loop_exceeded}
  end

  def loop(run, known_screen, _frame, ctx) do
    RunMemory.merge(ctx, %{screen: nil, task: if(run.errors > 0, do: "recovery"), step: nil})
    then = {__MODULE__, :located, [run]}

    cond do
      run.errors > 0 -> {:steps, Recovery.steps(keep(), run.errors, then)}
      known_screen && not Runner.fallback_screen?(known_screen) && identity?(known_screen) -> {:steps, [call(__MODULE__, :located, [run, {:ok, known_screen}])]}
      true -> {:steps, [locate_screen(then: then)]}
    end
  end

  def located(run, {:ok, screen}, _frame, ctx) do
    Ctx.log(ctx, :ok, "on screen: #{screen}")
    RunMemory.merge(ctx, %{screen: screen, task: nil})
    unless screen in @shop_screens, do: RunMemory.clear_shop_progress(ctx)
    run = %{run | run_state: sync_state(run.run_state, screen)}
    {:steps, dispatch(screen, run, ctx)}
  end

  def located(run, :unknown, _frame, ctx) do
    Ctx.log(ctx, :error, "screen not recognized")
    loop_error(:unknown_screen, run, ctx)
  end

  def go_home({:ok, screen}, _frame, _ctx), do: {:steps, [goto(screen, :home)]}

  def go_home(:unknown, _frame, ctx) do
    Ctx.log(ctx, :error, "screen not recognized")
    {:error, :unknown_screen}
  end

  def dispatched(run, {:continue, run_state}, _frame, _ctx), do: {:steps, [loop(%{run | run_state: run_state, iterations: run.iterations + 1, errors: 0}, nil)]}

  def dispatched(run, {:continue, run_state, screen}, _frame, _ctx),
    do: {:steps, [loop(%{run | run_state: run_state, iterations: run.iterations + 1, errors: 0}, screen)]}

  def dispatched(run, {:paused, run_state}, _frame, _ctx),
    do: {:steps, [checkpoint(), loop(%{run | run_state: run_state, iterations: run.iterations + 1, errors: 0}, nil)]}

  def dispatched(run, :run_complete, _frame, ctx) do
    Ctx.log(ctx, :ok, "mirror dungeon run complete — #{run.count - 1} remaining")
    RunnerForms.advance_mirror_dungeon_start()
    DailyProgress.record("md", 1)
    finish_run(run, true, ctx)
  end

  def dispatched(run, :gave_up, _frame, ctx) do
    progress = RunMemory.get(ctx, :run_progress, %{current: 0, total: 0})
    Ctx.log(ctx, :error, "mirror dungeon runner: gave up (#{inspect(RunMemory.give_up(ctx))}), counting run #{progress.current} as failed, #{run.count - 1} remaining, retrying #{run.cycle.team.name}")
    RunMemory.update(ctx, :failed_runs, [], &(&1 ++ [progress.current]))
    RunMemory.put_give_up(ctx, nil)
    RunMemory.reset_battle_retries(ctx)
    finish_run(run, false, ctx)
  end

  def dispatched(run, {:error, reason}, _frame, ctx), do: loop_error(reason, run, ctx)

  def resume(run, :at, run_state, result, frame, ctx), do: dispatched(run, continue_at(result, run_state), frame, ctx)
  def resume(run, :after, run_state, result, frame, ctx), do: dispatched(run, continue_after(result, run_state), frame, ctx)

  def season_pass_located({:ok, screen}, _frame, _ctx) do
    collect = [goto(screen, :season_pass_missions_tab)] ++ SeasonPassCollector.steps() ++ [goto(:season_pass_missions_tab, :home)]
    {:steps, [attempt(collect, else: {__MODULE__, :season_pass_failed, []})]}
  end

  def season_pass_located(:unknown, _frame, ctx) do
    Ctx.log(ctx, :error, "screen not recognized")
    season_pass_failed({:error, :unknown_screen}, nil, ctx)
  end

  def season_pass_failed({:error, reason}, _frame, ctx) do
    Ctx.log(ctx, :error, "mirror dungeon runner: collecting battle pass xp failed (#{inspect(reason)}), continuing")
    {:ok, nil}
  end

  def given_up_dungeon(run, _run_state, {:ok, _}, frame, ctx), do: dispatched(run, :gave_up, frame, ctx)
  def given_up_dungeon(run, run_state, result, frame, ctx), do: dispatched(run, continue_after(result, run_state), frame, ctx)

  def forfeited_dungeon(run, run_state, {:ok, _}, frame, ctx) do
    Ctx.log(ctx, :info, "mirror dungeon runner: forfeited from floor #{RunMemory.floor(ctx)}, evaluating rewards as a completed dungeon")
    RunMemory.put_give_up(ctx, nil)
    RunMemory.reset_battle_retries(ctx)
    dispatched(run, {:continue, run_state}, frame, ctx)
  end

  def forfeited_dungeon(run, run_state, result, frame, ctx), do: dispatched(run, continue_after(result, run_state), frame, ctx)

  def superposition_entered(run, run_state, {:ok, _} = result, frame, ctx) do
    RunMemory.raise_floor(ctx, max(RunMemory.floor(ctx) + 1, 6))
    resume(run, :after, run_state, result, frame, ctx)
  end

  def superposition_entered(run, run_state, result, frame, ctx), do: resume(run, :after, run_state, result, frame, ctx)

  def charged(run, run_state, {:error, :window_not_focused} = err, frame, ctx),
    do: dispatched(run, continue_after(err, Map.put(run_state, :enkephalin_charged?, false)), frame, ctx)

  def charged(run, run_state, {:error, reason}, frame, ctx) do
    Ctx.log(ctx, :error, "mirror dungeon runner: charging enkephalin failed (#{inspect(reason)}), starting the run anyway")
    dispatched(run, {:continue, run_state}, frame, ctx)
  end

  def charged(run, run_state, result, frame, ctx), do: dispatched(run, continue_after(result, run_state), frame, ctx)

  def claimed(run, {:ok, _}, frame, ctx), do: dispatched(run, :run_complete, frame, ctx)
  def claimed(run, {:error, :window_not_focused}, frame, ctx), do: dispatched(run, {:paused, %{own_run?: true}}, frame, ctx)
  def claimed(run, {:error, _} = err, frame, ctx), do: dispatched(run, err, frame, ctx)

  def team_selected(run, run_state, {:ok, _}, _frame, _ctx),
    do: {:steps, [goto(:team_selector_md, :grace, then: {__MODULE__, :run_started, [run, run_state]})]}

  def team_selected(run, run_state, result, frame, ctx), do: run_started(run, run_state, result, frame, ctx)

  def run_started(run, run_state, result, frame, ctx) do
    RunMemory.put_floor(ctx, 1)
    RunMemory.put_formation(ctx, nil)
    dispatched(run, continue_after(result, %{run_state | own_run?: true}), frame, ctx)
  end

  def team_reconfirmed(run, run_state, screen, {:ok, _}, _frame, _ctx), do: {:steps, [goto(screen, :battle, then: resume_after(run, run_state))]}
  def team_reconfirmed(run, run_state, _screen, result, frame, ctx), do: resume(run, :after, run_state, result, frame, ctx)

  def theme_pack_done(run, run_state, {:ok, _}, frame, ctx), do: dispatched(run, {:continue, run_state}, frame, ctx)
  def theme_pack_done(run, run_state, {:error, :window_not_focused}, frame, ctx), do: dispatched(run, {:paused, run_state}, frame, ctx)
  def theme_pack_done(run, _run_state, {:error, _} = err, frame, ctx), do: dispatched(run, err, frame, ctx)

  def event_done(run, run_state, {:ok, _} = ok, _frame, _ctx) do
    on_graph = [call(__MODULE__, :merge_graph_screen) | advance_dungeon_graph(run, run_state)]
    {:steps, [branch([{any_of([:dungeon_graph, :ego_gift_get]), on_graph}, default: [dispatch_outcome(run, continue_after(ok, run_state))]], wait: @settle_check_ms)]}
  end

  def event_done(run, run_state, result, frame, ctx), do: resume(run, :after, run_state, result, frame, ctx)

  def node_entered(run, run_state, {:ok, _} = ok, _frame, _ctx) do
    arrived = for screen <- [:event, :shop_super, :shop], do: {screen, [dispatch_outcome(run, {:continue, run_state, screen})]}
    {:steps, [branch(arrived ++ [default: [dispatch_outcome(run, continue_after(ok, run_state))]], wait: @fresh_check_ms)]}
  end

  def node_entered(run, run_state, result, frame, ctx), do: resume(run, :after, run_state, result, frame, ctx)

  def merge_graph_screen(_frame, ctx) do
    RunMemory.merge(ctx, %{screen: :dungeon_graph, task: nil})
    {:ok, nil}
  end

  def shop_done(run, run_state, {:ok, _}, _frame, _ctx), do: {:steps, [locate_screen(then: {__MODULE__, :leave_shop_located, [run, run_state]})]}
  def shop_done(run, run_state, result, frame, ctx), do: resume(run, :after, run_state, result, frame, ctx)

  def leave_shop_located(run, run_state, {:ok, screen}, frame, ctx) when screen in [:shop, :shop_super],
    do: leave_shop([invoke(DungeonPathPlanner, :leave_shop_for_boss, [])], run, run_state, frame, ctx)

  def leave_shop_located(run, run_state, {:ok, screen}, frame, ctx) when screen in @shop_screens,
    do: leave_shop([goto(screen, :shop), invoke(DungeonPathPlanner, :leave_shop_for_boss, [])], run, run_state, frame, ctx)

  def leave_shop_located(run, run_state, {:ok, _} = ok, frame, ctx), do: left_shop(run, run_state, ok, frame, ctx)
  def leave_shop_located(run, run_state, :unknown, frame, ctx), do: left_shop(run, run_state, {:error, :unknown_screen}, frame, ctx)

  def left_shop(run, run_state, result, frame, ctx) do
    if match?({:ok, _}, result) do
      Ops.reset_shop_purchases(ctx)
      RunMemory.put_bosses_only(ctx, true)
    end

    dispatched(run, continue_after(result, run_state), frame, ctx)
  end

  def await_next(run, run_state, screen, deadline, _frame, ctx) do
    %Screen{identity_hook: hook} = Catalog.find_screen(screen)
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Ctx.log(ctx, :info, "mirror dungeon runner: #{hook} didn't show within #{@next_screen_wait_ms}ms, re-localizing")
      dispatched(run, {:continue, run_state}, nil, ctx)
    else
      gift_popup = [goto(:ego_gift_get, :ego_gift_over, then: {__MODULE__, :gift_popup_cleared, [run, run_state, screen, deadline]})]

      clauses = [
        {hook, [dispatch_outcome(run, {:continue, run_state, screen})]},
        {:ego_gift_get, gift_popup},
        {:cabinet_reward, [dispatch_outcome(run, {:continue, run_state})]},
        default: [call(__MODULE__, :await_next, [run, run_state, screen, deadline])]
      ]

      {:steps, [branch(clauses, wait: remaining)]}
    end
  end

  def gift_popup_cleared(run, run_state, screen, deadline, {:ok, _}, frame, ctx), do: await_next(run, run_state, screen, deadline, frame, ctx)
  def gift_popup_cleared(run, run_state, _screen, _deadline, result, frame, ctx), do: resume(run, :after, run_state, result, frame, ctx)

  def continue_to_screen(run, run_state, screen, {:ok, _}, frame, ctx),
    do: await_next(run, run_state, screen, System.monotonic_time(:millisecond) + @next_screen_wait_ms, frame, ctx)

  def continue_to_screen(run, run_state, _screen, result, frame, ctx), do: resume(run, :after, run_state, result, frame, ctx)

  def cabinet_gift_clicks(_frame, ctx) do
    count = Enum.find_value(@cabinet_available_hooks, 1, fn {hook, n} -> if Engine.check(hook), do: n end)

    slots =
      case RunMemory.gift_plan(ctx) do
        nil -> [0, 1, 2]
        data -> GiftPlans.cabinet_slots(GiftPlans.normalize(data))
      end
      |> Enum.take(count)

    Ctx.log(ctx, :info, "cabinet gifts: #{count} pick(s), clicking slot(s) #{Enum.join(slots, ", ")}")
    {:steps, Enum.map(slots, &click(:"cabinet_ego_gift_#{&1}"))}
  end

  def clear_graph(deadline, _frame, ctx) do
    frame =
      case Capture.grab_frame() do
        {:ok, frame} -> frame
        {:error, _} -> nil
      end

    cond do
      frame && Runner.hook_matches?(frame, :ego_gift_get) ->
        RewardHelpers.record_ego_gift_items(frame, ctx)
        {:steps, [key(:enter), call(__MODULE__, :clear_graph, [deadline])]}

      frame && Runner.hook_matches?(frame, :dungeon_graph) ->
        {:ok, frame}

      System.monotonic_time(:millisecond) >= deadline ->
        Ctx.log(ctx, :info, "dungeon graph never showed clean, moving on anyway")
        {:ok, nil}

      true ->
        {:steps, [key(:enter), sleep(@clear_graph_poll_ms), call(__MODULE__, :clear_graph, [deadline])]}
    end
  end

  def detect_floor(_frame, ctx) do
    matches = Engine.check_all(@dungeon_graph_floor_hooks)

    case Enum.find(@dungeon_graph_floor_hooks, &Map.get(matches, &1, false)) do
      nil -> :ok
      hook -> RunMemory.raise_floor(ctx, floor_from_hook(hook))
    end

    {:ok, nil}
  end

  def unhandled(run, screen, _frame, ctx) do
    Ctx.log(ctx, :error, "mirror dungeon runner: no handler for screen #{inspect(screen)}")
    dispatched(run, {:error, {:unhandled_screen, screen}}, nil, ctx)
  end

  def handled_screen?(screen), do: screen in @recovery_kept_screens or Engine.in_battle?(screen)

  defp prepare_teams(picks, ctx) do
    Enum.reduce_while(picks, {:ok, []}, fn %{id: team_id, hook: hook} = pick, {:ok, acc} ->
      with {:ok, team} <- fetch_team(team_id, ctx),
           hook = Teams.pick_hook(team, hook),
           {:ok, team_type} <- resolve_team_type(hook, ctx) do
        prepared = %{
          id: team_id,
          name: team.name,
          hook: hook,
          mode_override: Resolver.parse_mode_override(Map.get(pick, :mode)),
          search_override: Resolver.parse_search_override(Map.get(pick, :search)),
          type: team_type,
          affinity: resolve_affinity(team),
          grace_picks: resolve_grace_picks(team)
        }

        {:cont, {:ok, acc ++ [prepared]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp activate(%{teams: teams, index: index} = cycle, ctx) do
    team = Enum.at(teams, index)
    if length(teams) > 1, do: Ctx.log(ctx, :info, "team cycle: using #{team.name} with #{team.hook} (#{index + 1}/#{length(teams)})")
    Map.put(cycle, :team, team)
  end

  defp next_team(%{teams: teams, index: index} = cycle, ctx), do: activate(%{cycle | index: rem(index + 1, length(teams))}, ctx)

  defp team_memory(team), do: %{id: team.id, name: team.name, hook: team.hook, type: team.type, affinity: Atom.to_string(team.affinity), mode_override: team.mode_override, search_override: team.search_override}

  defp fetch_team(team_id, ctx) do
    case Teams.get_team(team_id) do
      nil ->
        Ctx.log(ctx, :error, "team #{team_id} not found")
        {:error, :team_not_found}

      team ->
        {:ok, team}
    end
  end

  defp resolve_team_type(hook, ctx) do
    case hook do
      "team_" <> type when type != "" ->
        if type in Teams.team_types() do
          {:ok, String.to_atom(type)}
        else
          Ctx.log(ctx, :error, "team has an unrecognized hook team_#{type}")
          {:error, :unknown_team_hook}
        end

      hook when is_binary(hook) ->
        Ctx.log(ctx, :error, "team has an unrecognized hook #{hook}")
        {:error, :unknown_team_hook}

      nil ->
        Ctx.log(ctx, :error, "team has no team-select hook configured")
        {:error, :team_missing_hook}
    end
  end

  defp resolve_affinity(%{affinity: affinity}) when is_binary(affinity) do
    Enum.find(@affinities, :burn, &(Atom.to_string(&1) == affinity))
  end

  defp resolve_affinity(_team), do: :burn

  defp resolve_grace_picks(%{grace_picks: picks}) when is_list(picks) do
    Enum.map(picks, &grace_pick_index/1) |> Enum.reject(&is_nil/1)
  end

  defp resolve_grace_picks(_team), do: []

  defp grace_pick_index(%{"index" => index, "enhance" => enhance}) when is_integer(index) and enhance in [1, 2],
    do: {index, enhance}

  defp grace_pick_index(%{"index" => index}) when is_integer(index), do: {index, 0}
  defp grace_pick_index(index) when is_integer(index), do: {index, 0}
  defp grace_pick_index(_), do: nil

  defp keep, do: {__MODULE__, :handled_screen?}

  defp loop(run, known_screen), do: call(__MODULE__, :loop, [run, known_screen])

  defp dispatch_outcome(run, outcome), do: call(__MODULE__, :dispatched, [run, outcome])

  defp resume_at(run, run_state), do: {__MODULE__, :resume, [run, :at, run_state]}

  defp resume_after(run, run_state), do: {__MODULE__, :resume, [run, :after, run_state]}

  defp identity?(screen), do: match?(%Screen{identity_hook: hook} when not is_nil(hook), Catalog.find_screen(screen))

  defp finish_run(run, own_run?, ctx) do
    RunMemory.merge(ctx, %{ego_gifts: %{}, unfusable_gifts: MapSet.new()})

    cycle =
      if run.count > 1 do
        progress = RunMemory.get(ctx, :run_progress, %{current: 0, total: 0})
        cycle = if own_run?, do: next_team(run.cycle, ctx), else: run.cycle
        RunMemory.merge(ctx, %{floor: 1, run_progress: %{progress | current: progress.current + 1}, team: team_memory(cycle.team)})
        cycle
      else
        run.cycle
      end

    {:steps, [loop(%{run | count: run.count - 1, run_state: %{own_run?: own_run?}, iterations: 0, errors: 0, cycle: cycle}, nil)]}
  end

  defp loop_error(reason, run, ctx) do
    errors = run.errors + 1

    if errors >= @max_consecutive_errors do
      Ctx.log(ctx, :error, "mirror dungeon runner: #{errors} consecutive errors, giving up (last: #{inspect(reason)})")
      {:error, reason}
    else
      Ctx.log(ctx, :error, "mirror dungeon runner: error #{errors}/#{@max_consecutive_errors} (#{inspect(reason)}) — re-localizing and retrying")
      {:steps, [loop(%{run | iterations: run.iterations + 1, errors: errors}, nil)]}
    end
  end

  defp season_pass_steps(config) do
    if Map.get(config, :collect_xp?, false),
      do: [log(:info, "collecting battle pass xp"), locate_screen(then: {__MODULE__, :season_pass_located, []})],
      else: []
  end

  defp dispatch(screen, %{run_state: run_state, cycle: %{team: %{id: team_id, affinity: affinity, grace_picks: grace_picks} = team}, config: config} = run, ctx) do
    unless Engine.in_battle?(screen), do: RunMemory.reset_battle_retries(ctx)

    cond do
      screen == :dungeon_graph_danger_zone_skip ->
        [goto(screen, :dungeon_graph_danger_zone_skipped, then: resume_at(run, run_state))]

      screen == :dungeon_graph_superposition_popup and RunMemory.extreme?(team) ->
        [log(:info, "extreme mode is on, entering the next floors"), goto(screen, :dungeon_graph_superposition_entered, then: {__MODULE__, :superposition_entered, [run, run_state]})]

      screen == :dungeon_graph_superposition_popup ->
        [log(:info, "extreme mode is off, taking the rewards"), goto(screen, :exploration_reward, then: resume_at(run, run_state))]

      RunMemory.give_up?(ctx) and screen in [:dungeon_graph, :dungeon_progress] and forfeit_keeps_rewards?(ctx, config) ->
        Ctx.log(ctx, :info, "giving up (#{inspect(RunMemory.give_up(ctx))}) past floor 5, forfeiting the dungeon to keep its rewards")
        [goto(screen, :dungeon_forfeited, then: {__MODULE__, :forfeited_dungeon, [run, run_state]})]

      RunMemory.give_up?(ctx) and screen in [:dungeon_graph, :dungeon_progress] ->
        Ctx.log(ctx, :info, "giving up (#{inspect(RunMemory.give_up(ctx))}), leaving the dungeon to the window")
        [goto(screen, :dungeon_given_up, then: {__MODULE__, :given_up_dungeon, [run, run_state]})]

      RunMemory.give_up?(ctx) and screen in @door_family ->
        [dispatch_outcome(run, :gave_up)]

      screen in @enkephalin_charge_screens and charge_enkephalin?(run_state, config) ->
        charged_state = Map.put(run_state, :enkephalin_charged?, true)
        charge = EnkephalinCharger.steps(screen, Map.get(config, :enkephalin_convert_count, 0))
        [capture(charge, then: {__MODULE__, :charged, [run, charged_state]})]

      screen == :start_screen ->
        [goto(:start_screen, :home, then: resume_at(run, run_state))]

      screen in @home_screens ->
        [goto(screen, :md_door, then: resume_at(run, run_state))]

      screen in [:md_door, :md_door_unknown] ->
        superposition_steps(RunMemory.extreme?(team)) ++ [goto(screen, :md_door_enter, then: resume_at(run, run_state))]

      screen == :md_door_enter_popup ->
        [goto(:md_door_enter_popup, :team_select, then: resume_at(run, run_state))]

      screen == :md_door_progress and run_state.own_run? ->
        [log(:info, "the door has this runner's dungeon in progress, resuming it"), goto(:md_door_progress, :md_door_progress_resume, then: resume_at(run, run_state))]

      screen == :md_door_progress ->
        [log(:info, "the door has a dungeon in progress, halting it"), goto(:md_door_progress, :md_door_forfeit, then: resume_at(run, %{run_state | own_run?: false}))]

      screen == :md_door_forfeit ->
        [goto(:md_door_forfeit, :exploration_reward, then: resume_at(run, run_state))]

      screen == :md_door_session_expired ->
        [goto(:md_door_session_expired, :exploration_reward, then: resume_at(run, %{run_state | own_run?: false}))]

      screen == :exploration_complete ->
        [goto(:exploration_complete, :exploration_reward, then: resume_at(run, run_state))]

      screen == :exploration_reward ->
        exploration_steps(run, run_state, config)

      screen == :team_selector_md ->
        [capture([invoke(SelectTeamOnScreen, :run, [team_id, "md_battle", 1])], then: {__MODULE__, :team_selected, [run, run_state]})]

      screen == :grace ->
        steps = Enum.flat_map(grace_picks, &grace_pick_steps/1)
        ensure_saved = branch([{:grace_convert_starlight_checked, [click(:grace_convert_starlight_checked)]}, {:default, []}], wait: @fresh_check_ms)
        grace = steps ++ [goto(:grace, :grace_confirm), ensure_saved, goto(:grace_confirm, :cabinet_ego_gifts)]
        [capture(grace, then: resume_after(run, run_state))]

      screen == :grace_confirm ->
        [goto(:grace_confirm, :cabinet_ego_gifts, then: resume_after(run, run_state))]

      screen == :cabinet_ego_gifts ->
        cabinet_steps(affinity, run, run_state, ctx)

      screen == :gift_search ->
        search =
          case gift_search_names(ctx) do
            [] -> [goto(:gift_search, :theme_pack)]
            names -> GiftSearchPicker.steps(names)
          end

        [capture(search, then: {__MODULE__, :continue_to_screen, [run, run_state, :theme_pack]})]

      screen == :ego_gift_get ->
        [goto(:ego_gift_get, :ego_gift_over, then: resume_at(run, run_state))]

      screen == :theme_pack ->
        [capture([invoke(ThemePackSelector, :run, [team_id])], then: {__MODULE__, :theme_pack_done, [run, run_state]})]

      screen == :dungeon_graph ->
        advance_dungeon_graph(run, run_state)

      screen in @team_select_screens ->
        reconfirm = invoke(SelectTeamOnScreen, :run, [team_id, RunMemory.venue(ctx), RunMemory.floor(ctx)])
        [capture([reconfirm], then: {__MODULE__, :team_reconfirmed, [run, run_state, screen]})]

      Engine.in_battle?(screen) ->
        [capture(BattleLoop.steps(screen), then: resume_after(run, run_state))]

      screen == :event ->
        [goto(:event, :event_over, then: {__MODULE__, :event_done, [run, run_state]})]

      screen in [:shop, :shop_super] ->
        [capture(ShopRunner.program(:run), then: {__MODULE__, :shop_done, [run, run_state]})]

      screen in @shop_popup_screens ->
        [log(:info, "on #{screen}, backing out to the shop"), goto(screen, :shop, then: resume_at(run, run_state))]

      screen == :cabinet_reward ->
        [goto(:cabinet_reward, :cabinet_reward_over, then: resume_at(run, run_state))]

      screen == :mounting_trials ->
        [goto(:mounting_trials, :mounting_trials_over, then: {__MODULE__, :continue_to_screen, [run, run_state, :theme_pack]})]

      screen == :adversities ->
        [goto(:adversities, :adversities_over, then: resume_at(run, run_state))]

      screen == :encounter_reward ->
        [goto(:encounter_reward, :encounter_reward_over, then: resume_at(run, run_state))]

      screen == :battle_over_confirm ->
        [goto(:battle_over_confirm, :battle_turn_or_over, then: resume_at(run, run_state))]

      screen == :back_available ->
        [goto(:back_available, :any?, then: resume_after(run, run_state))]

      true ->
        [branch([{:exploration_reward, exploration_steps(run, run_state, config)}, default: [call(__MODULE__, :unhandled, [run, screen])]], wait: @settle_check_ms)]
    end
  end

  defp weekly_bonus?(:claim_weekly, _team), do: true
  defp weekly_bonus?(:claim_auto, team), do: RunMemory.full_hard?(team)
  defp weekly_bonus?(:claim, _team), do: false

  defp exploration_steps(%{cycle: %{team: team}} = run, %{own_run?: true}, config) do
    claim =
      case config.rewards do
        :none -> [log(:info, "mirror dungeon runner: dry run, refusing rewards") | ClaimRewards.steps(%{action: :give_up})]
        rewards -> ClaimRewards.steps(%{action: :claim, weekly_bonus?: weekly_bonus?(rewards, team)})
      end

    [capture(claim, then: {__MODULE__, :claimed, [run]})]
  end

  defp exploration_steps(run, run_state, _config) do
    forfeit = ClaimRewards.steps(%{action: :give_up, weekly_bonus?: true})
    [log(:info, "mirror dungeon runner: forfeiting stale/unclaimed rewards from a previous run"), capture(forfeit, then: resume_after(run, run_state))]
  end

  defp superposition_steps(extreme?) do
    wrong_state = if extreme?, do: :mirror_dungeon_door_superposition_off, else: :mirror_dungeon_door_superposition_on
    [branch([{wrong_state, [reclick_until_gone(wrong_state)]}, {:default, []}], wait: @fresh_check_ms)]
  end

  defp forfeit_keeps_rewards?(ctx, config), do: RunMemory.floor(ctx) >= 6 and config.rewards != :none

  defp grace_pick_steps({index, 0}), do: [click(:"grace_#{index}", settle_ms: 100)]
  defp grace_pick_steps({index, enhance}), do: [click(:"grace_#{index}", settle_ms: 100), click(:"grace_#{index}_#{enhance}", settle_ms: 100)]

  defp cabinet_steps(affinity, run, run_state, ctx) do
    GiftSearchPicker.reset(ctx)
    searching? = gift_search_names(ctx) != []

    toggle_search =
      if searching?,
        do: branch([{:cabinet_ego_gift_search_off, [click(:cabinet_ego_gift_search_off)]}, {:default, []}], wait: @fresh_check_ms),
        else: branch([{:cabinet_ego_gift_search_on, [click(:cabinet_ego_gift_search_on)]}, {:default, []}], wait: @fresh_check_ms)

    select_affinity =
      case Catalog.find_action(:cabinet_ego_gifts, :"select_#{affinity}") do
        nil -> [fail({:unknown_action, :cabinet_ego_gifts, :"select_#{affinity}"})]
        action -> Runner.action_program(:cabinet_ego_gifts, action)
      end

    steps = [toggle_search | select_affinity] ++ [call(__MODULE__, :cabinet_gift_clicks), goto(:cabinet_ego_gifts, :ego_gift_get)]
    next_screen = if searching?, do: :gift_search, else: :theme_pack
    [capture(steps, then: {__MODULE__, :continue_to_screen, [run, run_state, next_screen]})]
  end

  defp gift_search_names(ctx) do
    case RunMemory.gift_plan(ctx) do
      nil -> []
      data -> GiftPlans.normalize(data)["gift_search"]
    end
  end

  defp advance_dungeon_graph(run, run_state) do
    deadline = System.monotonic_time(:millisecond) + @clear_graph_timeout_ms
    graph = [call(__MODULE__, :clear_graph, [deadline]), call(__MODULE__, :detect_floor), goto(:dungeon_graph, :dungeon_graph_node)]
    [capture(graph, then: {__MODULE__, :node_entered, [run, run_state]})]
  end

  defp leave_shop(steps, run, run_state, _frame, _ctx), do: {:steps, [capture(steps, then: {__MODULE__, :left_shop, [run, run_state]})]}

  defp floor_from_hook(hook) do
    hook |> Atom.to_string() |> String.trim_leading("dungeon_graph_floor_") |> String.to_integer()
  end

  defp charge_enkephalin?(run_state, config) do
    Map.get(config, :collect_enkephalin?, false) and not Map.get(run_state, :enkephalin_charged?, false)
  end

  defp continue_at({:ok, screen}, run_state) when is_atom(screen), do: {:continue, run_state, screen}
  defp continue_at(result, run_state), do: continue_after(result, run_state)

  defp continue_after({:ok, _}, run_state), do: {:continue, run_state}
  defp continue_after({:error, :window_not_focused}, run_state), do: {:paused, run_state}
  defp continue_after({:error, _} = err, _run_state), do: err

  defp sync_state(run_state, screen) do
    if screen in @own_run_screens,
      do: %{run_state | own_run?: true},
      else: run_state
  end
end
