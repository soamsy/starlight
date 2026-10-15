defmodule StarlightBot.Automation.Scripts.MirrorDungeonRunner do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RunMemory}
  alias StarlightBot.Automation.Scripts.{ClaimRewards, SelectTeamOnScreen, ShopRunner, ThemePackSelector}
  alias StarlightBot.Ctx
  alias StarlightBot.Teams

  @max_dispatch_iterations 2_000
  @max_consecutive_errors 5
  @affinities ~w(bleed burn charge poise rupture sinking tremor)a
  @home_screens [:home, :home_drive, :home_window, :home_unknown]
  @door_family @home_screens ++ [:md_door, :md_door_unknown, :md_door_enter_popup, :md_door_progress]
  @dungeon_graph_floor_hooks Enum.map(1..5, &:"dungeon_graph_floor_#{&1}")

  def run(team_id, run_count, config, ctx \\ Ctx.new())

  def run(team_id, run_count, %{weekly_bonus?: wb} = config, ctx)
      when is_integer(run_count) and run_count >= 0 and is_boolean(wb) do
    {:ok, run_memory} = RunMemory.start_link()
    ctx = %{ctx | run_memory: run_memory}

    result =
      with {:ok, team} <- fetch_team(team_id, ctx),
           {:ok, team_type} <- resolve_team_type(team, ctx),
           {:ok, first_screen} <- localize_with_recovery(ctx) do
        affinity = resolve_affinity(team)
        config = Map.put(config, :grace_picks, resolve_grace_picks(team))
        RunMemory.put_team(ctx, %{id: team_id, type: team_type, affinity: Atom.to_string(affinity)})
        RunMemory.put_context(ctx, :mirror_dungeon)
        RunMemory.put_floor(ctx, 1)
        run_state = %{run_started?: first_screen not in @door_family}
        loop(run_count, run_state, 0, 0, team_id, team_type, affinity, config, ctx)
      end

    RunMemory.stop(ctx)
    result
  end

  def run(_team_id, _run_count, _config, ctx) do
    Ctx.log(ctx, :error, "run_count must be a non-negative integer and config must include weekly_bonus?")
    {:error, :invalid_arguments}
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

  defp resolve_team_type(team, ctx) do
    case team do
      %{hook: hook} when is_binary(hook) and hook != "" ->
        {:ok, hook |> String.replace_prefix("team_", "") |> String.to_existing_atom()}

      %{} ->
        Ctx.log(ctx, :error, "team has no team-select hook configured")
        {:error, :team_missing_hook}
    end
  rescue
    ArgumentError ->
      Ctx.log(ctx, :error, "team has an unrecognized hook")
      {:error, :unknown_team_hook}
  end

  defp resolve_affinity(%{affinity: affinity}) when is_binary(affinity) do
    Enum.find(@affinities, :burn, &(Atom.to_string(&1) == affinity))
  end

  defp resolve_affinity(_team), do: :burn

  defp resolve_grace_picks(%{grace_picks: picks}) when is_list(picks) do
    Enum.map(picks, &grace_pick_index/1) |> Enum.reject(&is_nil/1)
  end

  defp resolve_grace_picks(_team), do: []

  defp grace_pick_index(%{"index" => index}) when is_integer(index), do: index
  defp grace_pick_index(index) when is_integer(index), do: index
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

  defp localize_with_recovery(ctx) do
    case Engine.localize_with_recovery(ctx) do
      {:ok, screen} ->
        Ctx.log(ctx, :ok, "on screen: #{screen}")
        {:ok, screen}

      :unknown ->
        Ctx.log(ctx, :error, "screen not recognized")
        {:error, :unknown_screen}
    end
  end

  defp loop(run_count, _run_state, _iterations, _errors, _team_id, _team_type, _affinity, _config, ctx)
       when run_count <= 0 do
    case localize(ctx) do
      {:ok, screen} -> Engine.goto(screen, :home, ctx)
      {:error, _} = err -> err
    end
  end

  defp loop(_run_count, _run_state, iterations, _errors, _team_id, _team_type, _affinity, _config, ctx)
       when iterations > @max_dispatch_iterations do
    Ctx.log(ctx, :error, "mirror dungeon runner: exceeded #{@max_dispatch_iterations} dispatch iterations without completing this run")
    {:error, :dispatch_loop_exceeded}
  end

  defp loop(run_count, run_state, iterations, errors, team_id, team_type, affinity, config, ctx) do
    localize_fn = if errors > 0, do: &localize_with_recovery/1, else: &localize/1

    case localize_fn.(ctx) do
      {:ok, screen} ->
        screen
        |> dispatch(run_state, team_id, team_type, affinity, config, ctx)
        |> handle_dispatch_result(run_count, run_state, iterations, errors, team_id, team_type, affinity, config, ctx)

      {:error, reason} ->
        handle_loop_error(reason, run_count, run_state, iterations, errors, team_id, team_type, affinity, config, ctx)
    end
  rescue
    exception ->
      Ctx.log(ctx, :error, "mirror dungeon runner: crashed mid-dispatch: #{Exception.format(:error, exception, __STACKTRACE__)}")
      handle_loop_error({:exception, Exception.message(exception)}, run_count, run_state, iterations, errors, team_id, team_type, affinity, config, ctx)
  end

  defp handle_dispatch_result({:continue, run_state}, run_count, _prev_state, iterations, _errors, team_id, team_type, affinity, config, ctx) do
    loop(run_count, run_state, iterations + 1, 0, team_id, team_type, affinity, config, ctx)
  end

  defp handle_dispatch_result({:paused, run_state}, run_count, _prev_state, iterations, _errors, team_id, team_type, affinity, config, ctx) do
    :ok = resume_after_pause(ctx)
    loop(run_count, run_state, iterations + 1, 0, team_id, team_type, affinity, config, ctx)
  end

  defp handle_dispatch_result(:run_complete, run_count, _prev_state, _iterations, _errors, team_id, team_type, affinity, config, ctx) do
    Ctx.log(ctx, :ok, "mirror dungeon run complete — #{run_count - 1} remaining")
    loop(run_count - 1, %{run_started?: false}, 0, 0, team_id, team_type, affinity, config, ctx)
  end

  defp handle_dispatch_result({:error, reason}, run_count, prev_state, iterations, errors, team_id, team_type, affinity, config, ctx) do
    handle_loop_error(reason, run_count, prev_state, iterations, errors, team_id, team_type, affinity, config, ctx)
  end

  defp handle_loop_error(reason, run_count, run_state, iterations, errors, team_id, team_type, affinity, config, ctx) do
    errors = errors + 1

    if errors >= @max_consecutive_errors do
      Ctx.log(ctx, :error, "mirror dungeon runner: #{errors} consecutive errors, giving up (last: #{inspect(reason)})")
      {:error, reason}
    else
      Ctx.log(ctx, :error, "mirror dungeon runner: error #{errors}/#{@max_consecutive_errors} (#{inspect(reason)}) — re-localizing and retrying")
      loop(run_count, run_state, iterations + 1, errors, team_id, team_type, affinity, config, ctx)
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

  defp dispatch(screen, run_state, team_id, _team_type, affinity, config, ctx) do
    run_state = sync_state(run_state, screen)

    cond do
      screen in @home_screens ->
        Engine.goto(screen, :md_door, ctx) |> continue_after(run_state)

      screen in [:md_door, :md_door_unknown] ->
        Engine.goto(screen, :md_door_enter, ctx) |> continue_after(run_state)

      screen == :md_door_enter_popup ->
        Engine.goto(:md_door_enter_popup, :team_select, ctx) |> continue_after(run_state)

      screen == :md_door_progress ->
        Engine.goto(:md_door_progress, :md_door_progress_resume, ctx)
        |> continue_after(%{run_state | run_started?: true})

      screen == :md_door_forfeit ->
        Engine.goto(:md_door_forfeit, :exploration_reward, ctx) |> continue_after(run_state)

      screen == :md_door_session_expired ->
        Engine.goto(:md_door_session_expired, :exploration_reward, ctx)
        |> continue_after(%{run_state | run_started?: false})

      screen == :exploration_complete ->
        Engine.goto(:exploration_complete, :exploration_reward, ctx) |> continue_after(run_state)

      screen == :exploration_reward ->
        handle_exploration(run_state, config, ctx)

      screen == :team_selector_md ->
        start_run(team_id, run_state, ctx)

      screen == :grace ->
        apply_grace_picks(config, run_state, ctx)

      screen == :cabinet_ego_gifts ->
        apply_affinity_and_select_gift(affinity, run_state, ctx)

      screen == :ego_gift_get ->
        Engine.goto(:ego_gift_get, :ego_gift_over, ctx) |> continue_after(run_state)

      screen == :theme_pack ->
        advance_theme_pack(run_state, team_id, ctx)

      screen == :dungeon_graph ->
        detect_and_update_dungeon_graph_floor(ctx)
        Engine.goto(:dungeon_graph, :dungeon_graph_node, ctx) |> continue_after(run_state)

      screen in [:team_select, :team_selector, :team_selector_tall, :team_selector_gone] ->
        reconfirm_team(screen, team_id, run_state, ctx)

      Engine.in_battle?(screen) ->
        Engine.play_battle(screen, ctx) |> continue_after(run_state)

      screen == :event ->
        Engine.goto(:event, :event_over, ctx) |> continue_after(run_state)

      screen in [:shop, :shop_super] ->
        ShopRunner.run(ctx) |> leave_shop(ctx) |> continue_after(run_state)

      screen == :cabinet_reward ->
        Engine.goto(:cabinet_reward, :cabinet_reward_over, ctx) |> continue_after(run_state)

      screen == :mounting_trials ->
        Engine.goto(:mounting_trials, :mounting_trials_over, ctx) |> continue_after(run_state)

      screen == :encounter_reward ->
        Engine.goto(:encounter_reward, :encounter_reward_over, ctx) |> continue_after(run_state)

      screen == :battle_over_confirm ->
        Engine.goto(:battle_over_confirm, :battle_turn_or_over, ctx) |> continue_after(run_state)

      true ->
        handle_unrecognized_screen(screen, run_state, config, ctx)
    end
  end

  defp apply_grace_picks(config, run_state, ctx) do
    steps = Enum.map(config.grace_picks, &click(:"grace_#{&1}"))
    ensure_saved = [branch([{:grace_convert_starlight_checked, [click(:grace_convert_starlight_checked)]}, {:default, []}])]

    result =
      with {:ok, _} <- Engine.act(steps, ctx),
           {:ok, _} <- Engine.goto(:grace, :grace_confirm, ctx),
           {:ok, _} <- Engine.act(ensure_saved, ctx) do
        Engine.goto(:grace_confirm, :cabinet_ego_gifts, ctx)
      end

    continue_after(result, run_state)
  end

  defp apply_affinity_and_select_gift(affinity, run_state, ctx) do
    ensure_search_off = [branch([{:cabinet_ego_gift_search_on, [click(:cabinet_ego_gift_search_on)]}, {:default, []}])]

    result =
      with {:ok, _} <- Engine.act(ensure_search_off, ctx),
           {:ok, _} <- Engine.run_action(:cabinet_ego_gifts, :"select_#{affinity}", ctx),
           {:ok, _} <- select_all_available_gifts(ctx) do
        Engine.goto(:cabinet_ego_gifts, :ego_gift_get, ctx)
      end

    continue_after(result, run_state)
  end

  defp select_all_available_gifts(ctx) do
    Enum.reduce_while([:select_gift_1, :select_gift_2, :select_gift_3], {:ok, nil}, fn action, {:ok, _} ->
      case Engine.run_action(:cabinet_ego_gifts, action, ctx) do
        {:ok, _} = ok -> {:cont, ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp advance_theme_pack(run_state, team_id, ctx) do
    case ThemePackSelector.run(team_id, ctx) do
      {:ok, _} -> {:continue, run_state}
      {:error, :window_not_focused} -> {:paused, run_state}
      {:error, _} = err -> err
    end
  end

  defp detect_and_update_dungeon_graph_floor(ctx) do
    matches = Engine.check_all(@dungeon_graph_floor_hooks)

    case Enum.find(@dungeon_graph_floor_hooks, &Map.get(matches, &1, false)) do
      nil -> :ok
      hook -> RunMemory.put_floor(ctx, floor_from_hook(hook))
    end
  end

  defp floor_from_hook(hook) do
    hook |> Atom.to_string() |> String.trim_leading("dungeon_graph_floor_") |> String.to_integer()
  end

  defp reconfirm_team(screen, team_id, run_state, ctx) do
    result =
      with {:ok, _} <- SelectTeamOnScreen.run(team_id, ctx) do
        Engine.goto(screen, :battle, ctx)
      end

    continue_after(result, run_state)
  end

  defp start_run(team_id, run_state, ctx) do
    result =
      with {:ok, _} <- SelectTeamOnScreen.run(team_id, ctx) do
        Engine.goto(:team_selector_md, :grace, ctx)
      end

    continue_after(result, %{run_state | run_started?: true})
  end

  defp handle_exploration(run_state, config, ctx) do
    if run_state.run_started? do
      claim_run_completion(config, ctx)
    else
      forfeit_stale_rewards(run_state, ctx)
    end
  end

  defp claim_run_completion(config, ctx) do
    case ClaimRewards.run(%{action: :claim, weekly_bonus?: config.weekly_bonus?}, ctx) do
      {:ok, _} -> :run_complete
      {:error, :window_not_focused} -> {:paused, %{run_started?: true}}
      {:error, _} = err -> err
    end
  end

  defp forfeit_stale_rewards(run_state, ctx) do
    Ctx.log(ctx, :info, "mirror dungeon runner: forfeiting stale/unclaimed rewards from a previous run")
    ClaimRewards.run(%{action: :give_up, weekly_bonus?: true}, ctx) |> continue_after(run_state)
  end

  defp handle_unrecognized_screen(screen, run_state, config, ctx) do
    if Engine.check(:exploration_reward) do
      handle_exploration(run_state, config, ctx)
    else
      Ctx.log(ctx, :error, "mirror dungeon runner: no handler for screen #{inspect(screen)}")
      {:error, {:unhandled_screen, screen}}
    end
  end

  defp leave_shop({:ok, _} = _result, ctx) do
    case Engine.localize() do
      {:ok, screen} when screen in [:shop, :shop_super] -> Engine.goto(screen, :dungeon_graph, ctx)
      {:ok, screen} -> {:ok, screen}
      :unknown -> {:error, :unknown_screen}
    end
  end

  defp leave_shop({:error, _} = error, _ctx), do: error

  defp continue_after({:ok, _}, run_state), do: {:continue, run_state}
  defp continue_after({:error, :window_not_focused}, run_state), do: {:paused, run_state}
  defp continue_after({:error, _} = err, _run_state), do: err

  defp sync_state(run_state, _screen), do: run_state
end
