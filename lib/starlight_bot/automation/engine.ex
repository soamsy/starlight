defmodule StarlightBot.Automation.Engine do

  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.{Catalog, Runner}
  alias StarlightBot.Vision.Capture

  def localize, do: Runner.check_screens(Catalog.all_screens())

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

  def check_all(hook_specs) when is_list(hook_specs) do
    case Capture.grab_frame() do
      {:ok, frame} -> Map.new(hook_specs, &{&1, Runner.hook_matches?(frame, &1)})
      {:error, _} -> Map.new(hook_specs, &{&1, false})
    end
  end

  @battle_playing_screens [:battle, :battle_playing]
  @max_battle_loops 500
  @hiccup_backoff_ms 500
  @hiccup_max_attempts 5

  def play_battle(from, ctx \\ Ctx.new(), loops_left \\ @max_battle_loops)

  def play_battle(from, _ctx, 0), do: {:error, {:battle_turn_limit_exceeded, from}}

  def play_battle(from, ctx, loops_left) do
    target = if from in @battle_playing_screens, do: :battle_turn_or_over, else: :battle_playing

    case goto(from, target, ctx) do
      {:ok, screen} ->
        if screen in battle_screens() do
          play_battle(screen, ctx, loops_left - 1)
        else
          {:ok, screen}
        end

      {:error, :window_not_focused} = err ->
        err

      {:error, reason} ->
        recover_from_hiccup(reason, ctx, loops_left)
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
          {:ok, screen}
        end

      :unknown ->
        Ctx.log(ctx, :info, "still unrecognized (attempt #{attempt}/#{@hiccup_max_attempts}) — retrying in #{delay_ms}ms")
        Process.sleep(delay_ms)
        recover_from_hiccup(reason, ctx, loops_left, attempt + 1, delay_ms * 2)
    end
  end

  def in_battle?(screen), do: screen in battle_screens()

  defp battle_screens, do: [:battle | Enum.map(Catalog.refinements_of(:battle), & &1.name)]
end
