defmodule StarlightBot.Automation.BattleLoop do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{Engine, RunMemory}
  alias StarlightBot.Ctx

  @screens_awaiting_turn_or_over [:battle, :battle_playing, :battle_over_confirm]
  @max_battle_loops 500
  @max_defeat_failures 3
  @hiccup_backoff_ms 500
  @hiccup_max_attempts 7
  @give_up_screens [:battle_turn, :battle_chain, :battle_focused, :battle_settings_popup]

  def steps(from), do: [call(__MODULE__, :start, [from])]

  def start(from, _frame, ctx) do
    RunMemory.put_battle_turn(ctx, 1)
    {:steps, [play(from, @max_battle_loops)]}
  end

  def play(from, 0, _frame, _ctx), do: {:error, {:battle_turn_limit_exceeded, from}}

  def play(:battle_defeat, loops_left, _frame, ctx) do
    target =
      case RunMemory.claim_battle_retry(ctx) do
        {:retry, retry, max_retries} ->
          Ctx.log(ctx, :info, "battle lost, retrying (#{retry}/#{max_retries})")
          :battle_retried

        :give_up ->
          Ctx.log(ctx, :error, "battle lost, giving up (#{inspect(RunMemory.give_up(ctx))}) and returning to stage select")
          :battle_given_up
      end

    {:steps, [goto(:battle_defeat, target, then: {__MODULE__, :after_defeat, [loops_left]})]}
  end

  def play(from, loops_left, _frame, ctx) when from in @give_up_screens do
    if RunMemory.give_up?(ctx) do
      Ctx.log(ctx, :info, "giving up (#{inspect(RunMemory.give_up(ctx))}), leaving the battle through the settings menu")
      {:steps, [goto(from, :battle_given_up, then: {__MODULE__, :after_goto, [loops_left]})]}
    else
      advance(from, loops_left)
    end
  end

  def play(from, loops_left, _frame, _ctx), do: advance(from, loops_left)

  def after_defeat(loops_left, {:ok, _}, _frame, ctx) do
    RunMemory.put(ctx, :defeat_failures, 0)
    {:steps, [continue_battle(loops_left)]}
  end

  def after_defeat(_loops_left, {:error, :window_not_focused} = err, _frame, _ctx), do: err

  def after_defeat(loops_left, {:error, reason}, _frame, ctx) do
    failures = RunMemory.get(ctx, :defeat_failures, 0) + 1
    RunMemory.put(ctx, :defeat_failures, failures)

    if failures >= @max_defeat_failures do
      Ctx.log(ctx, :error, "defeat screen did not respond after #{failures} tries, stopping")
      RunMemory.put(ctx, :defeat_failures, 0)
      {:error, {:defeat_stuck, reason}}
    else
      {:steps, recover(reason, loops_left)}
    end
  end

  def after_goto(loops_left, {:ok, screen}, _frame, ctx), do: leave_or_continue(screen, loops_left, ctx)
  def after_goto(loops_left, {:error, :battle_left}, _frame, _ctx), do: {:steps, [continue_battle(loops_left)]}
  def after_goto(_loops_left, {:error, :window_not_focused} = err, _frame, _ctx), do: err
  def after_goto(loops_left, {:error, reason}, _frame, _ctx), do: {:steps, recover(reason, loops_left)}

  def after_locate(loops_left, {:ok, screen}, _frame, ctx), do: leave_or_continue(screen, loops_left, ctx)
  def after_locate(loops_left, :unknown, _frame, _ctx), do: {:steps, recover(:unknown_screen, loops_left)}

  def after_recover_locate(_reason, loops_left, _attempt, _delay_ms, {:ok, screen}, _frame, ctx) do
    if Engine.in_battle?(screen) do
      Ctx.log(ctx, :info, "still in battle (#{screen}) after the hiccup — continuing")
      {:steps, [play(screen, loops_left - 1)]}
    else
      Ctx.log(ctx, :ok, "resolved to #{screen} despite the hiccup — continuing")
      RunMemory.reset_battle_retries(ctx)
      {:steps, [result({:ok, screen})]}
    end
  end

  def after_recover_locate(reason, loops_left, attempt, delay_ms, :unknown, _frame, ctx) do
    Ctx.log(ctx, :info, "still unrecognized (attempt #{attempt}/#{@hiccup_max_attempts}) — retrying in #{delay_ms}ms")
    {:steps, [sleep(delay_ms) | recover_attempt(reason, loops_left, attempt + 1, delay_ms * 2)]}
  end

  defp play(from, loops_left), do: call(__MODULE__, :play, [from, loops_left])

  defp advance(from, loops_left) do
    target = if from in @screens_awaiting_turn_or_over, do: :battle_turn_or_over, else: :battle_playing
    {:steps, [goto(from, target, then: {__MODULE__, :after_goto, [loops_left]})]}
  end

  defp leave_or_continue(screen, loops_left, ctx) do
    if Engine.in_battle?(screen) do
      {:steps, [play(screen, loops_left - 1)]}
    else
      RunMemory.reset_battle_retries(ctx)
      {:steps, [result({:ok, screen})]}
    end
  end

  defp continue_battle(loops_left), do: locate_screen(then: {__MODULE__, :after_locate, [loops_left]})

  defp recover(reason, loops_left) do
    [log(:error, "battle hiccup: #{inspect(reason)} — re-localizing to check") | recover_attempt(reason, loops_left, 1, @hiccup_backoff_ms)]
  end

  defp recover_attempt(reason, _loops_left, attempt, _delay_ms) when attempt > @hiccup_max_attempts do
    [log(:error, "still unrecognized after #{@hiccup_max_attempts} attempts, giving up"), fail(reason)]
  end

  defp recover_attempt(reason, loops_left, attempt, delay_ms),
    do: [locate_screen(then: {__MODULE__, :after_recover_locate, [reason, loops_left, attempt, delay_ms]})]
end
