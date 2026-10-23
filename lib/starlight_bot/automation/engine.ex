defmodule StarlightBot.Automation.Engine do

  alias StarlightBot.Automation.BattleLoop
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

  def play_battle(from, ctx \\ Ctx.new()), do: Runner.run_steps(BattleLoop.steps(from), ctx)

  def in_battle?(screen), do: screen in battle_screens()

  defp battle_screens, do: [:battle, :battle_over_confirm, :battle_defeat | Enum.map(Catalog.refinements_of(:battle), & &1.name)]
end
