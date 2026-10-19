defmodule StarlightBot.Navigation.Screens.MountingTrials do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.{GiftPicker, RewardHelpers}
  alias StarlightBot.Ctx
  alias StarlightBot.Vision.HookRegistry

  @pick_delay_ms 400
  @tier_hooks [:mounting_trials_tier_4, :mounting_trials_tier_3, :mounting_trials_tier_2, :mounting_trials_tier_1]
  @selection_states [
    mounting_trials_2_of_2: {2, 2},
    mounting_trials_1_of_1: {1, 1},
    mounting_trials_1_of_2: {1, 2},
    mounting_trials_0_of_2: {0, 2},
    mounting_trials_0_of_1: {0, 1}
  ]
  @selection_hooks Keyword.keys(@selection_states)
  @max_select_attempts 4

  screen :mounting_trials, identity: :mounting_trials do
    transition to: :mounting_trials_over, do: [custom(&select_and_confirm_gifts/2)]
  end

  screen :mounting_trials_over, identity: nil, catch_all: true

  def selection_hooks, do: @selection_hooks

  def select_and_confirm_gifts(_frame, ctx), do: select_and_confirm(ctx, @max_select_attempts)

  defp select_and_confirm(_ctx, 0), do: {:error, :mounting_trials_selection_stuck}

  defp select_and_confirm(ctx, attempts) do
    with {:ok, _} <- Engine.act([await_any(@selection_hooks)], ctx) do
      case selection_state() do
        {total, total} ->
          with {:ok, _} <- Engine.act([click(confirm_hook(total))], ctx), do: RewardHelpers.dismiss_ego_gift_get(ctx)

        {selected, total} ->
          Ctx.log(ctx, :info, "mounting trials: #{selected}/#{total} selected, picking #{total - selected}")

          with {:ok, _} <- GiftPicker.pick(scan_hook(total), total - selected, @tier_hooks, :mounting_trials, ctx, @pick_delay_ms),
               do: select_and_confirm(ctx, attempts - 1)

        nil ->
          select_and_confirm(ctx, attempts - 1)
      end
    end
  end

  defp selection_state do
    matches = Engine.check_all(@selection_hooks)
    Enum.find_value(@selection_states, fn {hook, state} -> if matches[hook], do: state end)
  end

  defp scan_hook(2) do
    case HookRegistry.find(:mounting_trials_scan_area_2_available) do
      {:ok, %{}} -> :mounting_trials_scan_area_2_available
      _ -> :mounting_trials_scan_area_1_available
    end
  end

  defp scan_hook(_count), do: :mounting_trials_scan_area_1_available

  defp confirm_hook(1), do: :mounting_trials_1_of_1
  defp confirm_hook(2), do: :mounting_trials_2_of_2
end
