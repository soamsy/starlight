defmodule StarlightBot.Automation.Scripts.LuxcavationRunner do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.Scripts.SelectTeamOnScreen
  alias StarlightBot.Automation.SeasonPassCollector
  alias StarlightBot.Ctx

  @max_consecutive 10
  @max_navigation_retries 5

  @enkephalin_spend_state_hooks [
    :charge_enkephalin_tab_lunacy_0_10,
    :charge_enkephalin_tab_lunacy_1_10,
    :charge_enkephalin_tab_lunacy_2_10,
    :charge_enkephalin_tab_lunacy_3_10,
    :charge_enkephalin_tab_lunacy_4_10
  ]

  @enkephalin_spend_cost_hooks [
    :charge_enkephalin_tab_lunacy_cost_26,
    :charge_enkephalin_tab_lunacy_cost_52,
    :charge_enkephalin_tab_lunacy_cost_78,
    :charge_enkephalin_tab_lunacy_cost_104
  ]

  def run(
        team_id,
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
        team_id,
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
    with {:ok, start} <- localize(ctx) do
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
    Ctx.log(ctx, :info, "charging enkephalin (up to #{count} lunacy spend(s))")

    with {:ok, lunacy_tab} <- Engine.goto(home, :charge_enkephalin_lunacy_tab, ctx) do
      spend_lunacy(count, ctx)

      with {:ok, modules_tab} <- Engine.goto(lunacy_tab, :charge_enkephalin_modules_tab, ctx) do
        make_enkephalin_modules(ctx)
        Engine.goto(modules_tab, :home, ctx)
      end
    end
  end

  defp spend_lunacy(0, ctx) do
    Ctx.log(ctx, :info, "lunacy spend not requested — skipping")
  end

  defp spend_lunacy(target, ctx) do
    case detect_enkephalin_spent_count(ctx) do
      {:ok, spent} when spent >= target ->
        Ctx.log(ctx, :info, "already spent #{spent}/#{target} today — nothing to do")

      {:ok, spent} ->
        Ctx.log(ctx, :info, "spent #{spent} so far, spending up to #{target}")
        run_enkephalin_spend_steps(spent, target, ctx)

      :unknown ->
        Ctx.log(ctx, :info, "could not determine today's lunacy spend count — skipping")
    end
  end

  defp detect_enkephalin_spent_count(ctx) do
    matched_indices =
      Engine.check_all(@enkephalin_spend_state_hooks)
      |> Enum.filter(fn {_hook, matched?} -> matched? end)
      |> Enum.map(fn {hook, _matched?} -> Enum.find_index(@enkephalin_spend_state_hooks, &(&1 == hook)) end)

    case matched_indices do
      [spent] ->
        {:ok, spent}

      other ->
        Ctx.log(ctx, :info, "ambiguous lunacy spend state: #{length(other)} state(s) matched")
        :unknown
    end
  end

  defp run_enkephalin_spend_steps(spent, target, _ctx) when spent >= target, do: :ok

  defp run_enkephalin_spend_steps(spent, target, ctx) do
    cost_hook = Enum.at(@enkephalin_spend_cost_hooks, spent)

    case Engine.act(enkephalin_spend_steps(cost_hook), ctx) do
      {:ok, _} ->
        Ctx.log(ctx, :ok, "spent lunacy (#{spent + 1}/#{target})")
        run_enkephalin_spend_steps(spent + 1, target, ctx)

      {:error, reason} ->
        Ctx.log(ctx, :error, "spend lunacy failed at step #{spent + 1}: #{inspect(reason)} — moving on")
    end
  end

  defp enkephalin_spend_steps(cost_hook) do
    [
      retry_until(
        not_hook(cost_hook),
        [click(:charge_enkephalin_popup_confirm)],
        every: 1_000,
        tries: 2
      ),
      sleep(1000)
    ]
  end

  defp make_enkephalin_modules(ctx) do
    Ctx.log(ctx, :info, "making as many enkephalin modules as possible")

    case Engine.act(make_enkephalin_modules_steps(), ctx) do
      {:ok, _} -> Ctx.log(ctx, :ok, "modules made")
      {:error, reason} -> Ctx.log(ctx, :error, "make modules failed: #{inspect(reason)}")
    end
  end

  defp make_enkephalin_modules_steps do
    [
      click(:charge_enkephalin_tab_modules_all),
      sleep(300),
      click(:charge_enkephalin_popup_confirm),
      sleep(1000)
    ]
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
    Ctx.log(ctx, :info, "#{kind}: batch of #{batch} consecutive battle(s)")

    result =
      if Engine.in_battle?(screen) do
        Ctx.log(ctx, :info, "already at #{screen} — resuming battle instead of restarting the chunk")
        play_battle_resumable(screen, ctx)
      else
        with {:ok, screen} <- Engine.goto(screen, lux_screen(kind), ctx),
             :ok <- set_consecutive(kind, batch, ctx),
             {:ok, screen} <- Engine.goto(screen, :team_select, ctx),
             {:ok, _} <- SelectTeamOnScreen.run(team_id, ctx),
             {:ok, screen} <- Engine.goto(screen, :battle, ctx) do
          play_battle_resumable(screen, ctx)
        end
      end

    case result do
      {:ok, screen} when screen in [:lux_exp, :lux_thread] ->
        {:ok, screen}

      {:ok, screen} ->
        Ctx.log(ctx, :error, "landed on #{screen} after battle, expected :lux_exp/:lux_thread — stopping")
        {:error, {:unexpected_post_battle_screen, screen}}

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
    Ctx.log(ctx, :info, "window lost focus — paused, waiting for Resume")
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
