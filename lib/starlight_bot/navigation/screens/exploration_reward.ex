defmodule StarlightBot.Navigation.Screens.ExplorationReward do
  use StarlightBot.Navigation.DSL

  screen :exploration_reward, identity: :exploration_reward do
    transition to: :give_up_rewards, do: [reclick_until_gone(:exploration_reward_give_up)]
  end

  screen :give_up_rewards, identity: nil, catch_all: true do
  end

end
