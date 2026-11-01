defmodule StarlightBot.Automation.Scripts.LuxcavationRunner do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{BattleLoop, Engine, EnkephalinCharger, Recovery, RunMemory}
  alias StarlightBot.Automation.Scripts.SelectTeamOnScreen
  alias StarlightBot.Automation.SeasonPassCollector
  alias StarlightBot.{Ctx, DailyProgress}

  @max_consecutive 10
  @max_navigation_retries 10
  @post_battle_settle_tries 4
  @post_battle_settle_ms 500

  def program(team, exp_waves, thread_waves, collect_xp?, collect_enkephalin?, enkephalin_convert_count) do
    args = [team, exp_waves, thread_waves, collect_xp?, collect_enkephalin?, enkephalin_convert_count]
    [call(__MODULE__, :start, args)]
  end

  def start(
        %{exp: _, thread: _} = teams,
        exp_waves,
        thread_waves,
        collect_xp?,
        collect_enkephalin?,
        enkephalin_convert_count,
        _frame,
        ctx
      )
      when is_integer(exp_waves) and exp_waves >= 0 and
             is_integer(thread_waves) and thread_waves >= 0 and
             is_boolean(collect_xp?) and is_boolean(collect_enkephalin?) and
             is_integer(enkephalin_convert_count) and enkephalin_convert_count in 0..4 do
    RunMemory.put_context(ctx, :luxcavation)
    Ctx.log(ctx, :info, "Localizing…")

    lux = %{teams: teams, collect_xp?: collect_xp?, collect_enkephalin?: collect_enkephalin?, convert_count: enkephalin_convert_count}
    queue = kind_queue(:exp, exp_waves) ++ kind_queue(:thread, thread_waves)
    {:steps, Recovery.steps(no_keep(), 0, {__MODULE__, :started, [lux, queue]})}
  end

  def start(_team, _exp_waves, _thread_waves, _collect_xp?, _collect_enkephalin?, _count, _frame, ctx) do
    Ctx.log(
      ctx,
      :error,
      "exp/thread wave counts must be non-negative, enkephalin_convert_count must be 0-4"
    )

    {:error, :invalid_counts}
  end

  def started(_lux, _queue, :unknown, _frame, ctx) do
    Ctx.log(ctx, :error, "screen not recognized")
    {:error, :unknown_screen}
  end

  def started(lux, queue, {:ok, screen}, frame, ctx) do
    Ctx.log(ctx, :ok, "on screen: #{screen}")

    cond do
      not lux.collect_enkephalin? ->
        next(lux, queue, screen, frame, ctx)

      Engine.in_battle?(screen) ->
        Ctx.log(ctx, :info, "already at #{screen} — assuming enkephalin was already charged, skipping")
        next(lux, queue, screen, frame, ctx)

      true ->
        {:steps, [capture(EnkephalinCharger.steps(screen, lux.convert_count), then: {__MODULE__, :charged, [lux, queue]})]}
    end
  end

  def charged(lux, queue, {:ok, screen}, frame, ctx) when is_atom(screen), do: next(lux, queue, screen, frame, ctx)
  def charged(_lux, _queue, {:error, _} = err, _frame, _ctx), do: err

  def next(lux, [], screen, _frame, _ctx), do: {:steps, [goto(screen, :home, then: {__MODULE__, :home_reached, [lux]})]}

  def next(lux, [{:log, text} | queue], screen, frame, ctx) do
    Ctx.log(ctx, :info, text)
    next(lux, queue, screen, frame, ctx)
  end

  def next(lux, [{:batch, kind, size} | queue], screen, frame, ctx), do: batch(lux, kind, size, queue, screen, 0, frame, ctx)

  def batch(lux, kind, size, queue, screen, errors, _frame, ctx) do
    RunMemory.put_team(ctx, Map.fetch!(lux.teams, kind))
    RunMemory.put(ctx, :battle_confirmed, false)

    cond do
      RunMemory.give_up?(ctx) and not Engine.in_battle?(screen) ->
        gave_up(ctx)

      Engine.in_battle?(screen) ->
        Ctx.log(ctx, :info, "#{kind}: batch of #{size} consecutive battle(s)")
        Ctx.log(ctx, :info, "already at #{screen} — resuming battle instead of restarting the chunk")
        {:steps, [capture(BattleLoop.steps(screen), then: {__MODULE__, :battle_done, [lux, kind, size, queue, errors]})]}

      true ->
        Ctx.log(ctx, :info, "#{kind}: batch of #{size} consecutive battle(s)")
        {:steps, [goto(screen, lux_screen(kind), then: {__MODULE__, :at_lux_tab, [lux, kind, size, queue, errors]})]}
    end
  end

  def at_lux_tab(lux, kind, size, queue, errors, {:ok, screen}, _frame, _ctx) do
    steps = set_consecutive_steps(kind, size) ++ [goto(screen, :team_select)]
    {:steps, [capture(steps, then: {__MODULE__, :at_team_select, [lux, kind, size, queue, errors]})]}
  end

  def at_lux_tab(lux, kind, size, queue, errors, error, frame, ctx), do: battle_done(lux, kind, size, queue, errors, error, frame, ctx)

  def at_team_select(lux, kind, size, queue, errors, {:ok, screen}, _frame, _ctx) do
    select = invoke(SelectTeamOnScreen, :run, [Map.fetch!(lux.teams, kind).id, "lux", 1])
    {:steps, [capture([select, goto(screen, :battle)], then: {__MODULE__, :at_battle, [lux, kind, size, queue, errors]})]}
  end

  def at_team_select(lux, kind, size, queue, errors, error, frame, ctx), do: battle_done(lux, kind, size, queue, errors, error, frame, ctx)

  def at_battle(lux, kind, size, queue, errors, {:ok, screen}, _frame, _ctx),
    do: {:steps, [capture(BattleLoop.steps(screen), then: {__MODULE__, :battle_done, [lux, kind, size, queue, errors]})]}

  def at_battle(lux, kind, size, queue, errors, error, frame, ctx), do: battle_done(lux, kind, size, queue, errors, error, frame, ctx)

  def battle_done(lux, kind, size, queue, _errors, {:ok, screen}, frame, ctx) do
    if RunMemory.give_up?(ctx) do
      gave_up(ctx)
    else
      record_batch(kind, size, ctx)
      post_battle(lux, queue, screen, @post_battle_settle_tries, frame, ctx)
    end
  end

  def battle_done(lux, kind, size, queue, _errors, {:error, :window_not_focused}, _frame, _ctx),
    do: {:steps, [checkpoint(), locate_screen(then: {__MODULE__, :resumed, [lux, kind, size, queue]})]}

  def battle_done(lux, kind, size, queue, errors, error, frame, ctx), do: recover(lux, kind, size, queue, errors, error, frame, ctx)

  def resumed(lux, kind, size, queue, {:ok, screen}, frame, ctx) do
    Ctx.log(ctx, :ok, "on screen: #{screen}")

    unless Engine.in_battle?(screen),
      do: Ctx.log(ctx, :info, "#{kind}: resumed at #{screen}, outside the battle — redoing the batch")

    batch(lux, kind, size, queue, screen, 0, frame, ctx)
  end

  def resumed(_lux, _kind, _size, _queue, :unknown, _frame, ctx) do
    Ctx.log(ctx, :error, "screen not recognized")
    {:error, :unknown_screen}
  end

  def post_battle(lux, queue, screen, _tries, frame, ctx) when screen in [:lux_exp, :lux_thread], do: next(lux, queue, screen, frame, ctx)

  def post_battle(lux, queue, :lux_unknown, 0, frame, ctx) do
    Ctx.log(ctx, :info, "still on the luxcavation page without a tab settled, continuing from lux_unknown")
    next(lux, queue, :lux_unknown, frame, ctx)
  end

  def post_battle(lux, queue, :lux_unknown, tries, _frame, _ctx),
    do: {:steps, [sleep(@post_battle_settle_ms), locate_screen(then: {__MODULE__, :post_battle_located, [lux, queue, tries - 1]})]}

  def post_battle(lux, queue, screen, _tries, frame, ctx) do
    Ctx.log(ctx, :info, "landed on #{screen} after battle, routing from there")
    next(lux, queue, screen, frame, ctx)
  end

  def post_battle_located(lux, queue, tries, {:ok, screen}, frame, ctx), do: post_battle(lux, queue, screen, tries, frame, ctx)
  def post_battle_located(lux, queue, tries, :unknown, frame, ctx), do: post_battle(lux, queue, :lux_unknown, tries, frame, ctx)

  def recovered(lux, kind, size, queue, errors, _error, {:ok, screen}, frame, ctx) do
    Ctx.log(ctx, :ok, "pickoff point: #{screen}")
    batch(lux, kind, size, queue, screen, errors + 1, frame, ctx)
  end

  def recovered(lux, kind, size, queue, errors, error, :unknown, frame, ctx), do: recover(lux, kind, size, queue, errors + 1, error, frame, ctx)

  def home_reached(%{collect_xp?: true}, {:ok, screen}, _frame, ctx) do
    Ctx.log(ctx, :info, "collecting battle pass xp")
    collect = attempt(SeasonPassCollector.steps(), else: [])
    {:steps, [goto(screen, :season_pass_missions_tab), collect, goto(:season_pass_missions_tab, :home)]}
  end

  def home_reached(_lux, outcome, _frame, _ctx), do: {:steps, [result(outcome)]}

  def keeps_nothing?(_screen), do: false

  def batches(waves) when waves >= 0 do
    full = List.duplicate(@max_consecutive, div(waves, @max_consecutive))

    case rem(waves, @max_consecutive) do
      0 -> full
      rest -> full ++ [rest]
    end
  end

  defp record_batch(kind, size, ctx) do
    if RunMemory.get(ctx, :battle_confirmed, false), do: DailyProgress.record(Atom.to_string(kind), size)
    RunMemory.put(ctx, :battle_confirmed, false)
  end

  defp recover(_lux, _kind, _size, _queue, errors, error, _frame, ctx) when errors >= @max_navigation_retries do
    Ctx.log(ctx, :error, "navigation error #{inspect(error)} — giving up after #{errors} relocalize attempt(s)")
    error
  end

  defp recover(lux, kind, size, queue, errors, error, _frame, ctx) do
    Ctx.log(
      ctx,
      :error,
      "navigation error #{inspect(error)} — relocalizing to find a pickoff point (attempt #{errors + 1}/#{@max_navigation_retries})"
    )

    {:steps, Recovery.steps(no_keep(), errors, {__MODULE__, :recovered, [lux, kind, size, queue, errors, error]})}
  end

  defp gave_up(ctx) do
    Ctx.log(ctx, :error, "gave up (#{inspect(RunMemory.give_up(ctx))}), stopping")
    {:error, :gave_up}
  end

  defp no_keep, do: {__MODULE__, :keeps_nothing?}

  defp kind_queue(_kind, 0), do: []

  defp kind_queue(kind, waves) do
    [{:log, "starting #{waves} #{kind} wave(s) in batches of up to #{@max_consecutive}"}] ++
      Enum.map(batches(waves), &{:batch, kind, &1})
  end

  defp lux_screen(:exp), do: :lux_exp
  defp lux_screen(:thread), do: :lux_thread

  defp set_consecutive_steps(:exp, count),
    do: set_consecutive_steps(:lux_exp_consecutive_battle, :lux_exp_consecutive_minus, :lux_exp_consecutive_battle_close, count)

  defp set_consecutive_steps(:thread, count),
    do: set_consecutive_steps(:lux_consecutive_thread_battle, :lux_consecutive_thread_minus, :lux_thread_consecutive_battle_close, count)

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
