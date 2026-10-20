defmodule StarlightBot.Automation.Engine do

  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.{Catalog, Runner}
  alias StarlightBot.Vision.Capture

  @localize_timeout_ms 31_500
  @localize_poll_ms 200
  @check_poll_ms 100

  def localize, do: localize(System.monotonic_time(:millisecond) + @localize_timeout_ms)

  defp localize(deadline) do
    case Runner.check_screens(Catalog.all_screens()) do
      {:ok, _screen} = ok ->
        Runner.settle_fallback(ok, fn -> Runner.check_screens(Catalog.all_screens()) end)

      :unknown ->
        if System.monotonic_time(:millisecond) >= deadline do
          :unknown
        else
          Process.sleep(@localize_poll_ms)
          localize(deadline)
        end
    end
  end

  @escape_hook :safe_corner
  @escape_click_sleep_ms 300
  @max_escape_hops 3

  def localize_with_recovery(ctx \\ Ctx.new(), keep? \\ fn _screen -> false end) do
    case localize() do
      {:ok, screen} -> escape_then_localize(screen, ctx, keep?, @max_escape_hops)
      :unknown -> fallback_recovery(ctx)
    end
  end

  defp escape_then_localize(screen, _ctx, _keep?, 0), do: {:ok, screen}

  defp escape_then_localize(screen, ctx, keep?, hops_left) do
    case if(keep?.(screen), do: nil, else: Catalog.escape_transition(screen)) do
      nil ->
        {:ok, screen}

      transition ->
        Ctx.log(ctx, :info, "#{screen} has an escape route to #{transition.to} — leaving before resuming")
        Runner.run_plan([transition], ctx)

        case localize() do
          {:ok, next_screen} -> escape_then_localize(next_screen, ctx, keep?, hops_left - 1)
          :unknown -> fallback_recovery(ctx)
        end
    end
  end

  defp fallback_recovery(ctx) do
    Ctx.log(ctx, :error, "still unrecognized — trying #{@escape_hook}/esc/#{@escape_hook} to find a pickoff point")

    [
      [
        {:click, @escape_hook}, {:sleep, @escape_click_sleep_ms},
        {:key, :esc}, {:sleep, @escape_click_sleep_ms},
        {:click, @escape_hook}, {:sleep, @escape_click_sleep_ms}
      ],
      # [{:key, :esc}, {:sleep, @escape_click_sleep_ms}],
      # [{:click, @escape_hook}, {:sleep, @escape_click_sleep_ms}]
    ]
    |> Enum.reduce_while(:unknown, fn steps, _acc ->
      Runner.run_steps(steps, ctx)

      case localize() do
        {:ok, _} = ok -> {:halt, ok}
        :unknown -> {:cont, :unknown}
      end
    end)
  end

  def goto(same, same, ctx \\ Ctx.new())

  def goto(same, same, ctx) do
    Ctx.log(ctx, :ok, "already at #{same}")
    {:ok, same}
  end

  def goto(from, to, ctx) do
    case Catalog.plan_path(from, to) do
      {:error, :no_path} -> {:error, {:no_path, from, to}}
      {:ok, transitions} -> Runner.run_plan(transitions, ctx)
    end
  end

  def act(steps, ctx \\ Ctx.new()), do: Runner.run_steps(steps, ctx)

  def run_action(screen, action_name, ctx \\ Ctx.new()) do
    case Catalog.find_action(screen, action_name) do
      nil -> {:error, {:unknown_action, screen, action_name}}
      action -> Runner.run_action(screen, action, ctx)
    end
  end

  def check(hook_spec) do
    case Capture.grab_frame() do
      {:ok, frame} -> Runner.hook_matches?(frame, hook_spec)
      {:error, _} -> false
    end
  end

  def check_within(hook_spec, timeout_ms), do: poll_check(hook_spec, System.monotonic_time(:millisecond) + timeout_ms)

  defp poll_check(hook_spec, deadline) do
    cond do
      check(hook_spec) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true ->
        Process.sleep(@check_poll_ms)
        poll_check(hook_spec, deadline)
    end
  end

  def check_all(hook_specs) when is_list(hook_specs) do
    case Capture.grab_frame() do
      {:ok, frame} -> Map.new(hook_specs, &{&1, Runner.hook_matches?(frame, &1)})
      {:error, _} -> Map.new(hook_specs, &{&1, false})
    end
  end

  @screens_awaiting_turn_or_over [:battle, :battle_playing, :battle_over_confirm]
  @max_battle_loops 500
  @max_defeat_failures 3
  @hiccup_backoff_ms 500
  @hiccup_max_attempts 7
  @give_up_screens [:battle_turn, :battle_chain, :battle_focused, :battle_settings_popup]

  def play_battle(from, ctx \\ Ctx.new()) do
    RunMemory.put_battle_turn(ctx, 1)
    play_battle(from, ctx, @max_battle_loops)
  end

  defp play_battle(from, _ctx, 0), do: {:error, {:battle_turn_limit_exceeded, from}}

  defp play_battle(:battle_defeat, ctx, loops_left) do
    case resolve_defeat(ctx) do
      {:ok, _} ->
        RunMemory.put(ctx, :defeat_failures, 0)
        continue_battle(ctx, loops_left)

      {:error, :window_not_focused} = err ->
        err

      {:error, reason} ->
        failures = RunMemory.get(ctx, :defeat_failures, 0) + 1
        RunMemory.put(ctx, :defeat_failures, failures)

        if failures >= @max_defeat_failures do
          Ctx.log(ctx, :error, "defeat screen did not respond after #{failures} tries, stopping")
          RunMemory.put(ctx, :defeat_failures, 0)
          {:error, {:defeat_stuck, reason}}
        else
          recover_from_hiccup(reason, ctx, loops_left)
        end
    end
  end

  defp play_battle(from, ctx, loops_left) when from in @give_up_screens do
    if RunMemory.give_up?(ctx) do
      Ctx.log(ctx, :info, "giving up (#{inspect(RunMemory.give_up(ctx))}), leaving the battle through the settings menu")

      case goto(from, :battle_given_up, ctx) do
        {:ok, screen} -> leave_or_continue(screen, ctx, loops_left)
        {:error, :window_not_focused} = err -> err
        {:error, reason} -> recover_from_hiccup(reason, ctx, loops_left)
      end
    else
      advance_battle(from, ctx, loops_left)
    end
  end

  defp play_battle(from, ctx, loops_left), do: advance_battle(from, ctx, loops_left)

  defp advance_battle(from, ctx, loops_left) do
    target = if from in @screens_awaiting_turn_or_over, do: :battle_turn_or_over, else: :battle_playing

    case goto(from, target, ctx) do
      {:ok, screen} ->
        leave_or_continue(screen, ctx, loops_left)

      {:error, :battle_left} ->
        continue_battle(ctx, loops_left)

      {:error, :window_not_focused} = err ->
        err

      {:error, reason} ->
        recover_from_hiccup(reason, ctx, loops_left)
    end
  end

  defp leave_or_continue(screen, ctx, loops_left) do
    if screen in battle_screens() do
      play_battle(screen, ctx, loops_left - 1)
    else
      RunMemory.reset_battle_retries(ctx)
      {:ok, screen}
    end
  end

  defp continue_battle(ctx, loops_left) do
    case localize() do
      {:ok, screen} -> leave_or_continue(screen, ctx, loops_left)
      :unknown -> recover_from_hiccup(:unknown_screen, ctx, loops_left)
    end
  end

  defp resolve_defeat(ctx) do
    case RunMemory.claim_battle_retry(ctx) do
      {:retry, retry, max_retries} ->
        Ctx.log(ctx, :info, "battle lost, retrying (#{retry}/#{max_retries})")
        run_action(:battle_defeat, :retry, ctx)

      :give_up ->
        Ctx.log(ctx, :error, "battle lost, giving up (#{inspect(RunMemory.give_up(ctx))}) and returning to stage select")
        run_action(:battle_defeat, :to_stage_select, ctx)
    end
  end

  defp recover_from_hiccup(reason, ctx, loops_left) do
    Ctx.log(ctx, :error, "battle hiccup: #{inspect(reason)} — re-localizing to check")
    recover_from_hiccup(reason, ctx, loops_left, 1, @hiccup_backoff_ms)
  end

  defp recover_from_hiccup(reason, ctx, _loops_left, attempt, _delay_ms) when attempt > @hiccup_max_attempts do
    Ctx.log(ctx, :error, "still unrecognized after #{@hiccup_max_attempts} attempts, giving up")
    {:error, reason}
  end

  defp recover_from_hiccup(reason, ctx, loops_left, attempt, delay_ms) do
    case localize() do
      {:ok, screen} ->
        if screen in battle_screens() do
          Ctx.log(ctx, :info, "still in battle (#{screen}) after the hiccup — continuing")
          play_battle(screen, ctx, loops_left - 1)
        else
          Ctx.log(ctx, :ok, "resolved to #{screen} despite the hiccup — continuing")
          RunMemory.reset_battle_retries(ctx)
          {:ok, screen}
        end

      :unknown ->
        Ctx.log(ctx, :info, "still unrecognized (attempt #{attempt}/#{@hiccup_max_attempts}) — retrying in #{delay_ms}ms")
        Process.sleep(delay_ms)
        recover_from_hiccup(reason, ctx, loops_left, attempt + 1, delay_ms * 2)
    end
  end

  def in_battle?(screen), do: screen in battle_screens()

  defp battle_screens, do: [:battle, :battle_over_confirm, :battle_defeat | Enum.map(Catalog.refinements_of(:battle), & &1.name)]
end
