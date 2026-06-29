defmodule StarlightBot.Automation.Scripts.LuxcavationRunner do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.Scripts.SelectTeam
  alias StarlightBot.Ctx
  alias StarlightBot.Teams

  @max_consecutive 10

  def run(team_id, exp_count, thread_count, ctx \\ Ctx.new())

  def run(team_id, exp_count, thread_count, ctx)
      when is_integer(exp_count) and exp_count >= 0 and is_integer(thread_count) and thread_count >= 0 do
    with {:ok, team_type} <- resolve_team_type(team_id, ctx),
         {:ok, start} <- localize(ctx) do
      {:ok, start}
      |> run_kind(:exp, exp_count, team_type, ctx)
      |> run_kind(:thread, thread_count, team_type, ctx)
      |> case do
        {:ok, screen} -> Engine.goto(screen, :home, ctx)
        error -> error
      end
    end
  end

  def run(_team_id, _exp_count, _thread_count, ctx) do
    Ctx.log(ctx, :error, "exp_count/thread_count must be non-negative integers")
    {:error, :invalid_counts}
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

  defp resolve_team_type(team_id, ctx) do
    case Teams.get_team(team_id) do
      %{hook: hook} when is_binary(hook) and hook != "" ->
        Code.ensure_loaded(SelectTeam)
        {:ok, hook |> String.replace_prefix("team_", "") |> String.to_existing_atom()}

      %{} ->
        Ctx.log(ctx, :error, "team #{team_id} has no team-select hook configured")
        {:error, :team_missing_hook}

      nil ->
        Ctx.log(ctx, :error, "team #{team_id} not found")
        {:error, :team_not_found}
    end
  rescue
    ArgumentError ->
      Ctx.log(ctx, :error, "team #{team_id} has an unrecognized hook")
      {:error, {:unknown_team_hook, team_id}}
  end

  defp run_kind({:ok, screen}, _kind, 0, _team_type, _ctx), do: {:ok, screen}

  defp run_kind({:ok, screen}, kind, count, team_type, ctx) do
    Ctx.log(ctx, :info, "starting #{count} #{kind} run(s)")
    run_batches(screen, kind, batches(count), team_type, ctx)
  end

  defp run_kind(error, _kind, _count, _team_type, _ctx), do: error

  defp run_batches(screen, _kind, [], _team_type, _ctx), do: {:ok, screen}

  defp run_batches(screen, kind, [batch | rest], team_type, ctx) do
    case run_batch_with_resume(screen, kind, batch, team_type, ctx) do
      {:ok, screen} -> run_batches(screen, kind, rest, team_type, ctx)
      error -> error
    end
  end

  defp run_batch_with_resume(screen, kind, batch, team_type, ctx) do
    Ctx.log(ctx, :info, "#{kind}: batch of #{batch} consecutive battle(s)")

    result =
      if Engine.in_battle?(screen) do
        Ctx.log(ctx, :info, "already at #{screen} — resuming battle instead of restarting the chunk")
        play_battle_resumable(screen, ctx)
      else
        with {:ok, screen} <- Engine.goto(screen, lux_screen(kind), ctx),
             :ok <- set_consecutive(kind, batch, ctx),
             {:ok, screen} <- Engine.goto(screen, :team_select, ctx),
             {:ok, _} <- SelectTeam.run(team_type, ctx),
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
        run_batch_with_resume(resumed_screen, kind, batch, team_type, ctx)

      {:error, :window_not_focused} ->
        case resume_after_pause(ctx) do
          {:ok, resumed_screen} -> run_batch_with_resume(resumed_screen, kind, batch, team_type, ctx)
          {:error, _} = err -> err
        end

      error ->
        error
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

  def batches(0), do: []

  def batches(n) when n > 0 do
    batch = min(n, @max_consecutive)
    [batch | batches(n - batch)]
  end

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
