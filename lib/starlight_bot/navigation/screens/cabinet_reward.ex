defmodule StarlightBot.Navigation.Screens.CabinetReward do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.{GiftPicker, RewardHelpers}

  @tier_hooks [:cabinet_reward_tier_3, :cabinet_reward_tier_2, :cabinet_reward_tier_1]

  screen :cabinet_reward, identity: :cabinet_reward do
    transition to: :cabinet_reward_over do
      [
        call(__MODULE__, :select_tier_gift),
        click(:cabinet_reward_select),
        RewardHelpers.dismiss_ego_gift_get_step(leaving: :cabinet_reward)
      ]
    end
  end

  screen :cabinet_reward_over, identity: nil, catch_all: true

  def select_tier_gift(_frame, ctx), do: GiftPicker.pick(:cabinet_reward_scan_area, 1, @tier_hooks, :cabinet_reward, ctx, 0, anchor_hook: :cabinet_reward)
end
