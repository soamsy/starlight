defmodule StarlightBot.Navigation.Screens.MountingTrials do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.{GiftPicker, RewardHelpers, RunMemory}
  alias StarlightBot.{Ctx, GiftPlans}
  alias StarlightBot.Vision.HookRegistry

  @pick_delay_ms 300
  @settle_ms 100
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
  @selected_hook :mounting_trials_selected_orange
  @hp_hooks [mounting_trials_max_hp_text: 2.5, mounting_trials_hp_plus_2_5: 2.5, mounting_trials_hp_plus_5: 5, mounting_trials_hp_plus_7_5: 7.5, mounting_trials_hp_plus_10: 10, mounting_trials_hp_plus_15: 15, mounting_trials_hp_plus_17_5: 17.5, mounting_trials_hp_plus_35: 35, mounting_trials_hp_plus_40: 40, mounting_trials_hp_plus_72_5: 72.5]
  @hp_gate_hook :mounting_trials_max_hp_text

  screen :mounting_trials, identity: :mounting_trials do
    transition to: :mounting_trials_over, do: select_and_confirm(@max_select_attempts)
  end

  screen :mounting_trials_over, identity: nil, catch_all: true

  def selection_hooks, do: @selection_hooks

  defp select_and_confirm(0), do: [fail(:mounting_trials_selection_stuck)]
  defp select_and_confirm(attempts), do: [await_any(@selection_hooks), call(__MODULE__, :pick_or_confirm, [attempts])]

  def pick_or_confirm(attempts, _frame, ctx) do
    case selection_state() do
      {total, total} ->
        {:steps, [click(confirm_hook(total)), RewardHelpers.dismiss_ego_gift_get_step(leaving: :mounting_trials)]}

      {selected, total} ->
        mode = mode(ctx)
        Ctx.log(ctx, :info, "mounting trials: #{selected}/#{total} selected, picking #{total - selected} (#{GiftPlans.mounting_trials_mode_label(mode)})")
        opts = [selected_hook: @selected_hook] ++ if(mode == "avoid_hp", do: [hp_hooks: @hp_hooks, hp_gate_hook: @hp_gate_hook], else: [])

        with {:ok, _} <- GiftPicker.pick(scan_hook(total), total - selected, @tier_hooks, :mounting_trials, ctx, @pick_delay_ms, opts) do
          {:steps, [sleep(@settle_ms) | select_and_confirm(attempts - 1)]}
        end

      nil ->
        {:steps, select_and_confirm(attempts - 1)}
    end
  end

  defp mode(ctx) do
    case RunMemory.gift_plan(ctx) do
      %{} = data -> data |> GiftPlans.normalize() |> GiftPlans.mounting_trials_mode(RunMemory.floor(ctx))
      _ -> "best_gift"
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
