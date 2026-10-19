defmodule StarlightBot.Automation.Scripts.MirrorDungeonRunner do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, EnkephalinCharger, RewardHelpers, RunMemory}
  alias StarlightBot.Automation.Scripts.{ClaimRewards, GiftSearchPicker, SelectTeamOnScreen, ShopRunner, ThemePackSelector}
  alias StarlightBot.Automation.SeasonPassCollector
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.Ctx
  alias StarlightBot.{GiftPlans, Teams}
  alias StarlightBot.Navigation.{Catalog, Runner, Screen}
  alias StarlightBot.Navigation.Screens.Shop
  alias StarlightBot.Vision.Capture

  @max_dispatch_iterations 2_000
  @max_consecutive_errors 5
  @server_error_close_from_error 3
  @affinities ~w(bleed blunt burn charge pierce poise rupture sinking slash tremor)a
  @home_screens [:home, :home_drive, :home_window, :home_sinners, :home_theater, :home_extract, :home_dispense, :home_unknown]
  @door_family @home_screens ++ [:md_door, :md_door_unknown, :md_door_enter_popup, :md_door_progress]
  @enkephalin_charge_screens @home_screens ++ [:md_door, :md_door_unknown]
  @shop_popup_screens Shop.popup_screens()
  @shop_screens [:shop, :shop_super | @shop_popup_screens]
  @team_select_screens [:team_select, :team_selector, :team_selector_tall, :team_selector_gone]
  @in_dungeon_screens [
    :team_selector_md, :grace, :cabinet_ego_gifts, :gift_search, :ego_gift_get, :theme_pack, :dungeon_graph,
    :event, :shop, :shop_super, :cabinet_reward, :mounting_trials, :encounter_reward, :battle_over_confirm
  ] ++ @team_select_screens ++ @shop_popup_screens
  @recovery_kept_screens @in_dungeon_screens ++ [:md_door_unknown, :md_door_enter_popup, :md_door_progress, :md_door_forfeit]
  @dungeon_graph_floor_hooks Enum.map(1..5, &:"dungeon_graph_floor_#{&1}")
  @clear_graph_timeout_ms 8_000
  @clear_graph_poll_ms 100
  @settle_check_ms 800
  @cabinet_available_hooks [cabinet_ego_gift_available_3: 3, cabinet_ego_gift_available_2: 2, cabinet_ego_gift_available_1: 1]

  def run(team_ids, run_count, config, ctx \\ Ctx.new())

  def run([_ | _] = team_ids, run_count, %{weekly_bonus?: wb} = config, ctx)
      when is_integer(run_count) and run_count >= 0 and is_boolean(wb) do
    {:ok, run_memory} = RunMemory.start_link()
    ctx = %{ctx | run_memory: run_memory}

    result =
      with {:ok, teams} <- prepare_teams(team_ids, ctx),
           {:ok, first_screen} <- localize_at_start(ctx, 0) do
        cycle = activate(%{teams: teams, index: 0}, ctx)
        RunMemory.put_context(ctx, :mirror_dungeon)
        RunMemory.put_floor(ctx, 1)
        RunMemory.put(ctx, :run_progress, %{current: min(1, run_count), total: run_count})
        run_state = %{own_run?: first_screen not in @door_family}
        loop(run_count, run_state, 0, 0, cycle, config, ctx)
      end

    RunMemory.stop(ctx)
    result
  end

  def run(_team_ids, _run_count, _config, ctx) do
    Ctx.log(ctx, :error, "team_ids must be a non-empty list, run_count a non-negative integer, and config must include weekly_bonus?")
    {:error, :invalid_arguments}
  end

  defp prepare_teams(team_ids, ctx) do
    Enum.reduce_while(team_ids, {:ok, []}, fn team_id, {:ok, acc} ->
      with {:ok, team} <- fetch_team(team_id, ctx),
           {:ok, team_type} <- resolve_team_type(team, ctx) do
        prepared = %{id: team_id, name: team.name, type: team_type, affinity: resolve_affinity(team), grace_picks: resolve_grace_picks(team)}
        {:cont, {:ok, acc ++ [prepared]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp activate(%{teams: teams, index: index} = cycle, ctx) do
    team = Enum.at(teams, index)
    RunMemory.put_team(ctx, %{id: team.id, name: team.name, type: team.type, affinity: Atom.to_string(team.affinity)})
    if length(teams) > 1, do: Ctx.log(ctx, :info, "team cycle: using #{team.name} (#{index + 1}/#{length(teams)})")
    Map.put(cycle, :team, team)
  end

  defp next_team(%{teams: teams, index: index} = cycle, ctx), do: activate(%{cycle | index: rem(index + 1, length(teams))}, ctx)

  defp fetch_team(team_id, ctx) do
    case Teams.get_team(team_id) do
      nil ->
        Ctx.log(ctx, :error, "team #{team_id} not found")
        {:error, :team_not_found}

      team ->
        {:ok, team}
    end
  end

  defp resolve_team_type(team, ctx) do
    case team do
      %{hook: "team_" <> type} when type != "" ->
        if type in Teams.team_types() do
          {:ok, String.to_atom(type)}
        else
          Ctx.log(ctx, :error, "team has an unrecognized hook team_#{type}")
          {:error, :unknown_team_hook}
        end

      %{hook: hook} when is_binary(hook) and hook != "" ->
        Ctx.log(ctx, :error, "team has an unrecognized hook #{hook}")
        {:error, :unknown_team_hook}

      %{} ->
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

  defp localize(ctx) do
    case Engine.localize() do
      {:ok, screen} ->
        Ctx.log(ctx, :ok, "on screen: #{screen}")
        {:ok, screen}

      :unknown ->
        Ctx.log(ctx, :error, "screen not recognized")
        {:error, :unknown_screen}
    end
  end

  defp reuse_or_localize(screen, ctx) do
    cond do
      Runner.fallback_screen?(screen) ->
        {:ok, settled} = Runner.settle_fallback({:ok, screen}, fn -> Runner.check_screens(Catalog.all_screens()) end)
        Ctx.log(ctx, :ok, "on screen: #{settled}")
        {:ok, settled}

      match?(%Screen{identity_hook: hook} when not is_nil(hook), Catalog.find_screen(screen)) ->
        Ctx.log(ctx, :ok, "on screen: #{screen}")
        {:ok, screen}

      true ->
        localize(ctx)
    end
  end

  defp localize_with_recovery(ctx) do
    case Engine.localize_with_recovery(ctx, &handled_screen?/1) do
      {:ok, screen} ->
        Ctx.log(ctx, :ok, "on screen: #{screen}")
        {:ok, screen}

      :unknown ->
        Ctx.log(ctx, :error, "screen not recognized")
        {:error, :unknown_screen}
    end
  end

  defp localize_at_start(ctx, errors) do
    case localize_with_recovery(ctx) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        errors = errors + 1

        if errors >= @max_consecutive_errors do
          Ctx.log(ctx, :error, "mirror dungeon runner: #{errors} consecutive errors, giving up (last: #{inspect(reason)})")
          err
        else
          Ctx.log(ctx, :error, "mirror dungeon runner: error #{errors}/#{@max_consecutive_errors} (#{inspect(reason)}) — re-localizing and retrying")
          if errors >= @server_error_close_from_error, do: close_server_error(ctx)
          localize_at_start(ctx, errors)
        end
    end
  end

  defp loop(run_count, run_state, iterations, errors, cycle, config, ctx, known_screen \\ nil)

  defp loop(run_count, _run_state, _iterations, _errors, _cycle, _config, ctx, _known_screen)
       when run_count <= 0 do
    case localize(ctx) do
      {:ok, screen} -> Engine.goto(screen, :home, ctx)
      {:error, _} = err -> err
    end
  end

  defp loop(_run_count, _run_state, iterations, _errors, _cycle, _config, ctx, _known_screen)
       when iterations > @max_dispatch_iterations do
    Ctx.log(ctx, :error, "mirror dungeon runner: exceeded #{@max_dispatch_iterations} dispatch iterations without completing this run")
    {:error, :dispatch_loop_exceeded}
  end

  defp loop(run_count, run_state, iterations, errors, cycle, config, ctx, known_screen) do
    localize_fn =
      cond do
        errors > 0 -> &localize_with_recovery/1
        known_screen -> &reuse_or_localize(known_screen, &1)
        true -> &localize/1
      end

    RunMemory.merge(ctx, %{screen: nil, task: if(errors > 0, do: "recovery"), step: nil})

    case localize_fn.(ctx) do
      {:ok, screen} ->
        RunMemory.merge(ctx, %{screen: screen, task: nil})
        unless screen in @shop_screens, do: RunMemory.clear_shop_progress(ctx)
        run_state = sync_state(run_state, screen)

        screen
        |> dispatch(run_state, cycle, config, ctx)
        |> handle_dispatch_result(run_count, run_state, iterations, errors, cycle, config, ctx)

      {:error, reason} ->
        handle_loop_error(reason, run_count, run_state, iterations, errors, cycle, config, ctx)
    end
  rescue
    exception ->
      Ctx.log(ctx, :error, "mirror dungeon runner: crashed mid-dispatch: #{Exception.format(:error, exception, __STACKTRACE__)}")
      handle_loop_error({:exception, Exception.message(exception)}, run_count, run_state, iterations, errors, cycle, config, ctx)
  end

  defp handle_dispatch_result({:continue, run_state}, run_count, _prev_state, iterations, _errors, cycle, config, ctx) do
    loop(run_count, run_state, iterations + 1, 0, cycle, config, ctx)
  end

  defp handle_dispatch_result({:continue, run_state, screen}, run_count, _prev_state, iterations, _errors, cycle, config, ctx) do
    loop(run_count, run_state, iterations + 1, 0, cycle, config, ctx, screen)
  end

  defp handle_dispatch_result({:paused, run_state}, run_count, _prev_state, iterations, _errors, cycle, config, ctx) do
    :ok = resume_after_pause(ctx)
    loop(run_count, run_state, iterations + 1, 0, cycle, config, ctx)
  end

  defp handle_dispatch_result(:run_complete, run_count, _prev_state, _iterations, _errors, cycle, config, ctx) do
    Ctx.log(ctx, :ok, "mirror dungeon run complete — #{run_count - 1} remaining")
    finish_run(run_count, true, cycle, config, ctx)
  end

  defp handle_dispatch_result(:gave_up, run_count, _prev_state, _iterations, _errors, cycle, config, ctx) do
    progress = RunMemory.get(ctx, :run_progress, %{current: 0, total: 0})
    Ctx.log(ctx, :error, "mirror dungeon runner: gave up (#{inspect(RunMemory.give_up(ctx))}), counting run #{progress.current} as failed, #{run_count - 1} remaining")
    RunMemory.update(ctx, :failed_runs, [], &(&1 ++ [progress.current]))
    RunMemory.put_give_up(ctx, nil)
    RunMemory.reset_battle_retries(ctx)
    finish_run(run_count, false, cycle, config, ctx)
  end

  defp handle_dispatch_result({:error, reason}, run_count, prev_state, iterations, errors, cycle, config, ctx) do
    handle_loop_error(reason, run_count, prev_state, iterations, errors, cycle, config, ctx)
  end

  defp finish_run(run_count, own_run?, cycle, config, ctx) do
    RunMemory.put(ctx, :ego_gifts, %{})
    if Map.get(config, :collect_xp?, false), do: collect_season_pass(ctx)

    cycle =
      if run_count > 1 do
        cycle = next_team(cycle, ctx)
        progress = RunMemory.get(ctx, :run_progress, %{current: 0, total: 0})
        RunMemory.merge(ctx, %{floor: 1, run_progress: %{progress | current: progress.current + 1}})
        cycle
      else
        cycle
      end

    loop(run_count - 1, %{own_run?: own_run?}, 0, 0, cycle, config, ctx)
  end

  defp handle_loop_error(reason, run_count, run_state, iterations, errors, cycle, config, ctx) do
    errors = errors + 1

    if errors >= @max_consecutive_errors do
      Ctx.log(ctx, :error, "mirror dungeon runner: #{errors} consecutive errors, giving up (last: #{inspect(reason)})")
      {:error, reason}
    else
      Ctx.log(ctx, :error, "mirror dungeon runner: error #{errors}/#{@max_consecutive_errors} (#{inspect(reason)}) — re-localizing and retrying")
      if errors >= @server_error_close_from_error, do: close_server_error(ctx)
      loop(run_count, run_state, iterations + 1, errors, cycle, config, ctx)
    end
  end

  defp collect_season_pass(ctx) do
    Ctx.log(ctx, :info, "collecting battle pass xp")

    result =
      with {:ok, screen} <- localize(ctx),
           {:ok, _} <- Engine.goto(screen, :season_pass_missions_tab, ctx),
           :ok <- SeasonPassCollector.collect(ctx) do
        Engine.goto(:season_pass_missions_tab, :home, ctx)
      end

    with {:error, reason} <- result do
      Ctx.log(ctx, :error, "mirror dungeon runner: collecting battle pass xp failed (#{inspect(reason)}), continuing")
    end
  end

  defp close_server_error(ctx) do
    if Engine.check(:server_error_close) do
      Ctx.log(ctx, :info, "server error popup up, closing it")
      Runner.run_steps([{:click, :server_error_close}, {:sleep, 500}], ctx)
    end
  end

  defp resume_after_pause(ctx) do
    Ctx.log(ctx, :info, "paused (focus lost or pause requested), waiting for Resume")
    Ctx.pause(ctx)

    receive do
      :resume_mirror_dungeon -> :ok
    end

    Ctx.log(ctx, :ok, "resume clicked — continuing")
    :ok
  end

  defp dispatch(screen, run_state, %{team: %{id: team_id, affinity: affinity, grace_picks: grace_picks}}, config, ctx) do
    unless Engine.in_battle?(screen), do: RunMemory.reset_battle_retries(ctx)

    cond do
      RunMemory.give_up?(ctx) and screen in [:dungeon_graph, :dungeon_progress] ->
        Ctx.log(ctx, :info, "giving up (#{inspect(RunMemory.give_up(ctx))}), leaving the dungeon to the window")

        case Engine.goto(screen, :dungeon_given_up, ctx) do
          {:ok, _} -> :gave_up
          other -> continue_after(other, run_state)
        end

      RunMemory.give_up?(ctx) and screen in @door_family ->
        :gave_up

      screen in @enkephalin_charge_screens and charge_enkephalin?(run_state, config) ->
        charge_enkephalin(screen, run_state, config, ctx)

      screen == :start_screen ->
        Engine.goto(:start_screen, :home, ctx) |> continue_at(run_state)

      screen in @home_screens ->
        Engine.goto(screen, :md_door, ctx) |> continue_at(run_state)

      screen in [:md_door, :md_door_unknown] ->
        Engine.goto(screen, :md_door_enter, ctx) |> continue_at(run_state)

      screen == :md_door_enter_popup ->
        Engine.goto(:md_door_enter_popup, :team_select, ctx) |> continue_at(run_state)

      screen == :md_door_progress and run_state.own_run? ->
        Ctx.log(ctx, :info, "the door has this runner's dungeon in progress, resuming it")
        Engine.goto(:md_door_progress, :md_door_progress_resume, ctx) |> continue_at(run_state)

      screen == :md_door_progress ->
        Ctx.log(ctx, :info, "the door has a dungeon in progress, halting it")
        Engine.goto(:md_door_progress, :md_door_forfeit, ctx) |> continue_at(%{run_state | own_run?: false})

      screen == :md_door_forfeit ->
        Engine.goto(:md_door_forfeit, :exploration_reward, ctx) |> continue_at(run_state)

      screen == :md_door_session_expired ->
        Engine.goto(:md_door_session_expired, :exploration_reward, ctx)
        |> continue_at(%{run_state | own_run?: false})

      screen == :exploration_complete ->
        Engine.goto(:exploration_complete, :exploration_reward, ctx) |> continue_at(run_state)

      screen == :exploration_reward ->
        handle_exploration(run_state, config, ctx)

      screen == :team_selector_md ->
        start_run(team_id, run_state, ctx)

      screen == :grace ->
        apply_grace_picks(grace_picks, run_state, ctx)

      screen == :cabinet_ego_gifts ->
        apply_affinity_and_select_gift(affinity, run_state, ctx)

      screen == :gift_search ->
        handle_gift_search(run_state, ctx)

      screen == :ego_gift_get ->
        Engine.goto(:ego_gift_get, :ego_gift_over, ctx) |> continue_at(run_state)

      screen == :theme_pack ->
        advance_theme_pack(run_state, team_id, ctx)

      screen == :dungeon_graph ->
        advance_dungeon_graph(run_state, ctx)

      screen in @team_select_screens ->
        reconfirm_team(screen, team_id, run_state, ctx)

      Engine.in_battle?(screen) ->
        Engine.play_battle(screen, ctx) |> continue_after(run_state)

      screen == :event ->
        finish_event(run_state, ctx)

      screen in [:shop, :shop_super] ->
        ShopRunner.run(ctx) |> leave_shop(ctx) |> continue_after(run_state)

      screen in @shop_popup_screens ->
        Ctx.log(ctx, :info, "on #{screen}, backing out to the shop")
        Engine.goto(screen, :shop, ctx) |> continue_at(run_state)

      screen == :cabinet_reward ->
        Engine.goto(:cabinet_reward, :cabinet_reward_over, ctx) |> continue_at(run_state)

      screen == :mounting_trials ->
        Engine.goto(:mounting_trials, :mounting_trials_over, ctx) |> continue_at(run_state)

      screen == :encounter_reward ->
        Engine.goto(:encounter_reward, :encounter_reward_over, ctx) |> continue_at(run_state)

      screen == :battle_over_confirm ->
        Engine.goto(:battle_over_confirm, :battle_turn_or_over, ctx) |> continue_at(run_state)

      true ->
        handle_unrecognized_screen(screen, run_state, config, ctx)
    end
  end

  defp apply_grace_picks(grace_picks, run_state, ctx) do
    steps = Enum.flat_map(grace_picks, &grace_pick_steps/1)
    ensure_saved = [branch([{:grace_convert_starlight_checked, [click(:grace_convert_starlight_checked)]}, {:default, []}])]

    result =
      with {:ok, _} <- Engine.act(steps, ctx),
           {:ok, _} <- Engine.goto(:grace, :grace_confirm, ctx),
           {:ok, _} <- Engine.act(ensure_saved, ctx) do
        Engine.goto(:grace_confirm, :cabinet_ego_gifts, ctx)
      end

    continue_after(result, run_state)
  end

  defp grace_pick_steps({index, 0}), do: [click(:"grace_#{index}")]
  defp grace_pick_steps({index, enhance}), do: [click(:"grace_#{index}"), click(:"grace_#{index}_#{enhance}")]

  defp apply_affinity_and_select_gift(affinity, run_state, ctx) do
    GiftSearchPicker.reset(ctx)

    toggle_search =
      if gift_search_names(ctx) == [],
        do: [branch([{:cabinet_ego_gift_search_on, [click(:cabinet_ego_gift_search_on)]}, {:default, []}])],
        else: [branch([{:cabinet_ego_gift_search_off, [click(:cabinet_ego_gift_search_off)]}, {:default, []}])]

    result =
      with {:ok, _} <- Engine.act(toggle_search, ctx),
           {:ok, _} <- Engine.run_action(:cabinet_ego_gifts, :"select_#{affinity}", ctx),
           {:ok, _} <- select_cabinet_gifts(ctx) do
        Engine.goto(:cabinet_ego_gifts, :ego_gift_get, ctx)
      end

    continue_after(result, run_state)
  end

  defp gift_search_names(ctx) do
    case RunMemory.gift_strategy(ctx) do
      nil -> []
      data -> GiftPlans.normalize(data)["gift_search"]
    end
  end

  defp handle_gift_search(run_state, ctx) do
    result =
      case gift_search_names(ctx) do
        [] -> Engine.goto(:gift_search, :theme_pack, ctx)
        names -> GiftSearchPicker.run(names, ctx)
      end

    continue_after(result, run_state)
  end

  defp select_cabinet_gifts(ctx) do
    count = Enum.find_value(@cabinet_available_hooks, 1, fn {hook, n} -> if Engine.check(hook), do: n end)

    slots =
      case RunMemory.gift_strategy(ctx) do
        nil -> [0, 1, 2]
        data -> GiftPlans.cabinet_slots(GiftPlans.normalize(data))
      end
      |> Enum.take(count)

    Ctx.log(ctx, :info, "cabinet gifts: #{count} pick(s), clicking slot(s) #{Enum.join(slots, ", ")}")
    Engine.act(Enum.map(slots, &click(:"cabinet_ego_gift_#{&1}")), ctx)
  end

  defp advance_theme_pack(run_state, team_id, ctx) do
    case ThemePackSelector.run(team_id, ctx) do
      {:ok, _} -> {:continue, run_state}
      {:error, :window_not_focused} -> {:paused, run_state}
      {:error, _} = err -> err
    end
  end

  defp finish_event(run_state, ctx) do
    case Engine.goto(:event, :event_over, ctx) do
      {:ok, _} = ok ->
        if Engine.check_within(any_of([:dungeon_graph, :ego_gift_get]), @settle_check_ms) do
          RunMemory.merge(ctx, %{screen: :dungeon_graph, task: nil})
          advance_dungeon_graph(run_state, ctx)
        else
          continue_after(ok, run_state)
        end

      other ->
        continue_after(other, run_state)
    end
  end

  defp advance_dungeon_graph(run_state, ctx) do
    result =
      with {:ok, _} <- clear_to_dungeon_graph(ctx, System.monotonic_time(:millisecond) + @clear_graph_timeout_ms) do
        detect_and_update_dungeon_graph_floor(ctx)
        Engine.goto(:dungeon_graph, :dungeon_graph_node, ctx)
      end

    continue_after(result, run_state)
  end

  defp clear_to_dungeon_graph(ctx, deadline) do
    frame =
      case Capture.grab_frame() do
        {:ok, frame} -> frame
        {:error, _} -> nil
      end

    cond do
      frame && Runner.hook_matches?(frame, :ego_gift_get) ->
        RewardHelpers.record_ego_gift_items(frame, ctx)
        with {:ok, _} <- Engine.act([key(:enter)], ctx), do: clear_to_dungeon_graph(ctx, deadline)

      frame && Runner.hook_matches?(frame, :dungeon_graph) ->
        {:ok, frame}

      System.monotonic_time(:millisecond) >= deadline ->
        Ctx.log(ctx, :info, "dungeon graph never showed clean, moving on anyway")
        {:ok, nil}

      true ->
        with {:ok, _} <- Engine.act([key(:enter)], ctx) do
          Process.sleep(@clear_graph_poll_ms)
          clear_to_dungeon_graph(ctx, deadline)
        end
    end
  end

  defp detect_and_update_dungeon_graph_floor(ctx) do
    matches = Engine.check_all(@dungeon_graph_floor_hooks)

    case Enum.find(@dungeon_graph_floor_hooks, &Map.get(matches, &1, false)) do
      nil -> :ok
      hook -> RunMemory.raise_floor(ctx, floor_from_hook(hook))
    end
  end

  defp floor_from_hook(hook) do
    hook |> Atom.to_string() |> String.trim_leading("dungeon_graph_floor_") |> String.to_integer()
  end

  defp reconfirm_team(screen, team_id, run_state, ctx) do
    result =
      with {:ok, _} <- SelectTeamOnScreen.run(team_id, RunMemory.venue(ctx), RunMemory.floor(ctx), ctx) do
        Engine.goto(screen, :battle, ctx)
      end

    continue_after(result, run_state)
  end

  defp start_run(team_id, run_state, ctx) do
    result =
      with {:ok, _} <- SelectTeamOnScreen.run(team_id, "md_battle", 1, ctx) do
        Engine.goto(:team_selector_md, :grace, ctx)
      end

    RunMemory.put_floor(ctx, 1)
    RunMemory.put_formation(ctx, nil)
    continue_after(result, %{run_state | own_run?: true})
  end

  defp handle_exploration(run_state, config, ctx) do
    if run_state.own_run? do
      claim_run_completion(config, ctx)
    else
      forfeit_stale_rewards(run_state, ctx)
    end
  end

  defp claim_run_completion(config, ctx) do
    case ClaimRewards.run(%{action: :claim, weekly_bonus?: config.weekly_bonus?}, ctx) do
      {:ok, _} -> :run_complete
      {:error, :window_not_focused} -> {:paused, %{own_run?: true}}
      {:error, _} = err -> err
    end
  end

  defp forfeit_stale_rewards(run_state, ctx) do
    Ctx.log(ctx, :info, "mirror dungeon runner: forfeiting stale/unclaimed rewards from a previous run")
    ClaimRewards.run(%{action: :give_up, weekly_bonus?: true}, ctx) |> continue_after(run_state)
  end

  defp handle_unrecognized_screen(screen, run_state, config, ctx) do
    if Engine.check_within(:exploration_reward, @settle_check_ms) do
      handle_exploration(run_state, config, ctx)
    else
      Ctx.log(ctx, :error, "mirror dungeon runner: no handler for screen #{inspect(screen)}")
      {:error, {:unhandled_screen, screen}}
    end
  end

  defp leave_shop({:ok, _} = _result, ctx) do
    left =
      case Engine.localize() do
        {:ok, screen} when screen in @shop_screens -> Engine.goto(screen, :dungeon_graph, ctx)
        {:ok, screen} -> {:ok, screen}
        :unknown -> {:error, :unknown_screen}
      end

    if match?({:ok, _}, left) do
      Ops.reset_shop_purchases(ctx)
      RunMemory.put_bosses_only(ctx, true)
    end

    left
  end

  defp leave_shop({:error, _} = error, _ctx), do: error

  defp charge_enkephalin?(run_state, config) do
    Map.get(config, :collect_enkephalin?, false) and not Map.get(run_state, :enkephalin_charged?, false)
  end

  defp charge_enkephalin(screen, run_state, config, ctx) do
    run_state = Map.put(run_state, :enkephalin_charged?, true)

    case EnkephalinCharger.charge(screen, Map.get(config, :enkephalin_convert_count, 0), ctx) do
      {:error, :window_not_focused} = err ->
        continue_after(err, Map.put(run_state, :enkephalin_charged?, false))

      {:error, reason} ->
        Ctx.log(ctx, :error, "mirror dungeon runner: charging enkephalin failed (#{inspect(reason)}), starting the run anyway")
        {:continue, run_state}

      result ->
        continue_after(result, run_state)
    end
  end

  defp continue_at({:ok, screen}, run_state) when is_atom(screen), do: {:continue, run_state, screen}
  defp continue_at(result, run_state), do: continue_after(result, run_state)

  defp continue_after({:ok, _}, run_state), do: {:continue, run_state}
  defp continue_after({:error, :window_not_focused}, run_state), do: {:paused, run_state}
  defp continue_after({:error, _} = err, _run_state), do: err

  defp sync_state(run_state, screen) do
    if screen in @in_dungeon_screens or Engine.in_battle?(screen),
      do: %{run_state | own_run?: true},
      else: run_state
  end

  defp handled_screen?(screen), do: screen in @recovery_kept_screens or Engine.in_battle?(screen)
end
