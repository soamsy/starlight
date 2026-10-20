defmodule StarlightBot.Automation.Scripts.LuxcavationRunner do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, EnkephalinCharger, RunMemory}
  alias StarlightBot.Automation.Scripts.SelectTeamOnScreen
  alias StarlightBot.Automation.SeasonPassCollector
  alias StarlightBot.Ctx

  @max_consecutive 10
  @max_navigation_retries 5
  @post_battle_settle_tries 4
  @post_battle_settle_ms 500

  def run(
        team,
        exp_consecutive,
        exp_repeats,
        thread_consecutive,
        thread_repeats,
        collect_xp?,
        collect_enkephalin?,
        enkephalin_convert_count,
        ctx \\ Ctx.new()
      )

  def run(
        %{id: team_id} = team,
        exp_consecutive,
        exp_repeats,
        thread_consecutive,
        thread_repeats,
        collect_xp?,
        collect_enkephalin?,
        enkephalin_convert_count,
        ctx
      )
      when is_integer(exp_consecutive) and exp_consecutive in 0..@max_consecutive and
             is_integer(exp_repeats) and exp_repeats >= 0 and
             is_integer(thread_consecutive) and thread_consecutive in 0..@max_consecutive and
             is_integer(thread_repeats) and thread_repeats >= 0 and
             is_boolean(collect_xp?) and is_boolean(collect_enkephalin?) and
             is_integer(enkephalin_convert_count) and enkephalin_convert_count in 0..4 do
    {:ok, run_memory} = RunMemory.start_link()
    ctx = %{ctx | run_memory: run_memory}
    RunMemory.put_team(ctx, team)
    RunMemory.put_context(ctx, :luxcavation)

    result =
      with {:ok, start} <- localize_with_recovery(ctx) do
        {:ok, start}
        |> maybe_charge_enkephalin(collect_enkephalin?, enkephalin_convert_count, ctx)
        |> run_kind(:exp, exp_consecutive, exp_repeats, team_id, ctx)
        |> run_kind(:thread, thread_consecutive, thread_repeats, team_id, ctx)
        |> case do
          {:ok, screen} -> Engine.goto(screen, :home, ctx)
          error -> error
        end
        |> maybe_collect_xp(collect_xp?, ctx)
      end

    RunMemory.stop(ctx)
    result
  end

  def run(
        _team_id,
        _exp_consecutive,
        _exp_repeats,
        _thread_consecutive,
        _thread_repeats,
        _collect_xp?,
        _collect_enkephalin?,
        _enkephalin_convert_count,
        ctx
      ) do
    Ctx.log(
      ctx,
      :error,
      "exp/thread consecutive counts must be 0-#{@max_consecutive}, repeat counts must be non-negative, enkephalin_convert_count must be 0-4"
    )

    {:error, :invalid_counts}
  end

  defp maybe_collect_xp(result, false, _ctx), do: result
  defp maybe_collect_xp({:error, _} = error, true, _ctx), do: error

  defp maybe_collect_xp({:ok, screen}, true, ctx) do
    Ctx.log(ctx, :info, "collecting battle pass xp")

    with {:ok, _} <- Engine.goto(screen, :season_pass_missions_tab, ctx),
         :ok <- SeasonPassCollector.collect(ctx) do
      Engine.goto(:season_pass_missions_tab, :home, ctx)
    end
  end

  defp maybe_charge_enkephalin(result, false, _count, _ctx), do: result

  defp maybe_charge_enkephalin({:ok, home}, true, count, ctx) do
    if Engine.in_battle?(home) do
      Ctx.log(ctx, :info, "already at #{home} — assuming enkephalin was already charged, skipping")
      {:ok, home}
    else
      EnkephalinCharger.charge(home, count, ctx)
    end
  end

  defp localize(ctx) do
    Ctx.log(ctx, :info, "Localizing…")

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
    Ctx.log(ctx, :info, "Localizing…")

    case Engine.localize_with_recovery(ctx) do
      {:ok, screen} ->
        Ctx.log(ctx, :ok, "on screen: #{screen}")
        {:ok, screen}

      :unknown ->
        Ctx.log(ctx, :error, "screen not recognized")
        {:error, :unknown_screen}
    end
  end

  defp run_kind({:ok, screen}, _kind, _consecutive, 0, _team_id, _ctx), do: {:ok, screen}

  defp run_kind({:ok, screen}, kind, consecutive, repeats, team_id, ctx) do
    Ctx.log(ctx, :info, "starting #{repeats} x #{consecutive} consecutive #{kind} run(s) (#{consecutive * repeats} total)")
    run_batches(screen, kind, batches(consecutive, repeats), team_id, ctx)
  end

  defp run_kind(error, _kind, _consecutive, _repeats, _team_id, _ctx), do: error

  defp run_batches(screen, _kind, [], _team_id, _ctx), do: {:ok, screen}

  defp run_batches(screen, kind, [batch | rest], team_id, ctx) do
    case run_batch_with_resume(screen, kind, batch, team_id, ctx) do
      {:ok, screen} -> run_batches(screen, kind, rest, team_id, ctx)
      error -> error
    end
  end

  defp run_batch_with_resume(screen, kind, batch, team_id, ctx, errors \\ 0)

  defp run_batch_with_resume(screen, kind, batch, team_id, ctx, errors) do
    if RunMemory.give_up?(ctx) and not Engine.in_battle?(screen) do
      gave_up(ctx)
    else
      start_or_resume_batch(screen, kind, batch, team_id, ctx, errors)
    end
  end

  defp start_or_resume_batch(screen, kind, batch, team_id, ctx, errors) do
    Ctx.log(ctx, :info, "#{kind}: batch of #{batch} consecutive battle(s)")

    result =
      if Engine.in_battle?(screen) do
        Ctx.log(ctx, :info, "already at #{screen} — resuming battle instead of restarting the chunk")
        play_battle_resumable(screen, ctx)
      else
        with {:ok, screen} <- Engine.goto(screen, lux_screen(kind), ctx),
             :ok <- set_consecutive(kind, batch, ctx),
             {:ok, screen} <- Engine.goto(screen, :team_select, ctx),
             {:ok, _} <- SelectTeamOnScreen.run(team_id, "lux", 1, ctx),
             {:ok, screen} <- Engine.goto(screen, :battle, ctx) do
          play_battle_resumable(screen, ctx)
        end
      end

    case result do
      {:ok, _screen} = ok ->
        if RunMemory.give_up?(ctx), do: gave_up(ctx), else: check_post_battle(ok, ctx)

      {:battle_lost, resumed_screen} ->
        Ctx.log(ctx, :info, "#{kind}: #{batch} consecutive battle(s) lost while paused — redoing the batch")
        run_batch_with_resume(resumed_screen, kind, batch, team_id, ctx)

      {:error, :window_not_focused} ->
        case resume_after_pause(ctx) do
          {:ok, resumed_screen} -> run_batch_with_resume(resumed_screen, kind, batch, team_id, ctx)
          {:error, _} = err -> err
        end

      error ->
        recover_from_navigation_error(error, kind, batch, team_id, errors, ctx)
    end
  end

  defp gave_up(ctx) do
    Ctx.log(ctx, :error, "gave up (#{inspect(RunMemory.give_up(ctx))}), stopping")
    {:error, :gave_up}
  end

  defp check_post_battle(result, ctx), do: check_post_battle(result, @post_battle_settle_tries, ctx)

  defp check_post_battle({:ok, screen}, _tries, _ctx) when screen in [:lux_exp, :lux_thread], do: {:ok, screen}

  defp check_post_battle({:ok, :lux_unknown}, 0, ctx) do
    Ctx.log(ctx, :info, "still on the luxcavation page without a tab settled, continuing from lux_unknown")
    {:ok, :lux_unknown}
  end

  defp check_post_battle({:ok, :lux_unknown}, tries, ctx) do
    Process.sleep(@post_battle_settle_ms)

    case Engine.localize() do
      {:ok, screen} -> check_post_battle({:ok, screen}, tries - 1, ctx)
      :unknown -> check_post_battle({:ok, :lux_unknown}, tries - 1, ctx)
    end
  end

  defp check_post_battle({:ok, screen}, _tries, ctx) do
    Ctx.log(ctx, :error, "landed on #{screen} after battle, expected :lux_exp/:lux_thread — stopping")
    {:error, {:unexpected_post_battle_screen, screen}}
  end

  defp recover_from_navigation_error(error, _kind, _batch, _team_id, errors, ctx) when errors >= @max_navigation_retries do
    Ctx.log(ctx, :error, "navigation error #{inspect(error)} — giving up after #{errors} relocalize attempt(s)")
    error
  end

  defp recover_from_navigation_error(error, kind, batch, team_id, errors, ctx) do
    Ctx.log(
      ctx,
      :error,
      "navigation error #{inspect(error)} — relocalizing to find a pickoff point (attempt #{errors + 1}/#{@max_navigation_retries})"
    )

    case Engine.localize_with_recovery(ctx) do
      {:ok, screen} ->
        Ctx.log(ctx, :ok, "pickoff point: #{screen}")
        run_batch_with_resume(screen, kind, batch, team_id, ctx, errors + 1)

      :unknown ->
        recover_from_navigation_error(error, kind, batch, team_id, errors + 1, ctx)
    end
  end

  defp play_battle_resumable(screen, ctx) do
    case Engine.play_battle(screen, ctx) do
      {:error, :window_not_focused} ->
        case resume_after_pause(ctx) do
          {:ok, resumed_screen} ->
            if Engine.in_battle?(resumed_screen) do
              Ctx.log(ctx, :info, "resumed mid-battle at #{resumed_screen} — continuing")
              play_battle_resumable(resumed_screen, ctx)
            else
              Ctx.log(ctx, :info, "resumed at #{resumed_screen}, outside the battle — treating as lost")
              {:battle_lost, resumed_screen}
            end

          {:error, _} = err ->
            err
        end

      other ->
        other
    end
  end

  defp resume_after_pause(ctx) do
    Ctx.log(ctx, :info, "paused (focus lost or pause requested), waiting for Resume")
    Ctx.pause(ctx)

    receive do
      :resume_luxcavation -> :ok
    end

    Ctx.log(ctx, :ok, "resume clicked — continuing")
    localize(ctx)
  end

  defp lux_screen(:exp), do: :lux_exp
  defp lux_screen(:thread), do: :lux_thread

  def batches(_consecutive, 0), do: []
  def batches(consecutive, repeats) when repeats > 0, do: List.duplicate(consecutive, repeats)

  defp set_consecutive(:exp, count, ctx) do
    set_consecutive_steps(:lux_exp_consecutive_battle, :lux_exp_consecutive_minus, :lux_exp_consecutive_battle_close, count)
    |> run_set_consecutive(ctx)
  end

  defp set_consecutive(:thread, count, ctx) do
    set_consecutive_steps(:lux_consecutive_thread_battle, :lux_consecutive_thread_minus, :lux_thread_consecutive_battle_close, count)
    |> run_set_consecutive(ctx)
  end

  defp run_set_consecutive(steps, ctx) do
    case Engine.act(steps, ctx) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp set_consecutive_steps(open_hook, minus_hook, close_hook, count) do
    [
      click(open_hook),
      click(minus_hook),
      type(Integer.to_string(count)),
      key(:enter),
      click(close_hook)
    ]
  end
end
