defmodule StarlightBot.Navigation.Screens.EgoGiftGet do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.RewardHelpers

  screen :ego_gift_get, identity: :ego_gift_get do
    transition to: :ego_gift_over,
      do: [RewardHelpers.record_ego_gift_items_step(), RewardHelpers.dismiss_ego_gift_get_step()]
  end

  screen :ego_gift_over, identity: nil, catch_all: true
end
