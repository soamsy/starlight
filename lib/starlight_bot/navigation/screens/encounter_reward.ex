defmodule StarlightBot.Navigation.Screens.EncounterReward do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.RewardHelpers
  alias StarlightBot.Ctx

  @default_location_timeout 1_000
  @ready_wait_ms 2_000
  @ready_settle_ms 100
  @close_timeout_ms 8_000
  @gift_popup_grace_ms 300
  @priority_hooks [
    :encounter_reward_gain_cost,
    :encounter_reward_random_gift,
    :encounter_reward_starlight,
    :encounter_reward_resources
  ]

  screen :encounter_reward, identity: :encounter_reward do
    transition to: :encounter_reward_over do
      [
        branch([{any_of(@priority_hooks), [sleep(@ready_settle_ms)]}], wait: @ready_wait_ms),
        call(__MODULE__, :select_priority_gift),
        click(:encounter_reward_confirm),
        await_reward_closed()
      ]
    end
  end

  screen :encounter_reward_over, identity: nil, catch_all: true

  defp await_reward_closed do
    branch(
      [
        {:ego_gift_get, collect_ego_gift()},
        {:encounter_reward_0_of_1, []},
        {not_hook(:encounter_reward), [branch([{:ego_gift_get, collect_ego_gift()}], wait: @gift_popup_grace_ms)]},
        default: [fail(:encounter_reward_not_closed)]
      ],
      wait: @close_timeout_ms
    )
  end

  defp collect_ego_gift do
    [
      log(:info, "encounter reward gave an EGO gift, dismissing it"),
      RewardHelpers.record_ego_gift_items_step(),
      RewardHelpers.dismiss_ego_gift_get_step(leaving: :encounter_reward)
    ]
  end

  def select_priority_gift(_frame, ctx) do
    case RewardHelpers.find_and_click_first(@priority_hooks, ctx) do
      {:ok, {:clicked, _rect}} ->
        {:ok, nil}

      {:ok, :none} ->
        Ctx.log(ctx, :info, "no priority gift visible — retrying default location")
        {:steps, [retry_until(:encounter_reward_1_of_1, [click(:encounter_reward_default_location)], timeout: @default_location_timeout)]}

      {:error, _} = err ->
        err
    end
  end
end
