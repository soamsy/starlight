defmodule StarlightBot.Navigation.Screens.CabinetReward do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.RewardHelpers

  @tier_hooks [:cabinet_reward_tier_3, :cabinet_reward_tier_2, :cabinet_reward_tier_1]

  screen :cabinet_reward, identity: :cabinet_reward do
    transition to: :cabinet_reward_over do
      [
        custom(&select_tier_gift/2),
        click(:cabinet_reward_select),
        RewardHelpers.dismiss_ego_gift_get_step()
      ]
    end
  end

  screen :cabinet_reward_over, identity: nil, catch_all: true

  def select_tier_gift(_frame, ctx), do: RewardHelpers.select_best_available_gift(@tier_hooks, :cabinet_reward, ctx)
end
