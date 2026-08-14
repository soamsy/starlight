defmodule StarlightBot.Navigation.Screens.ExplorationComplete do
  use StarlightBot.Navigation.DSL

  screen :exploration_complete, identity: :exploration_complete do
    transition to: :exploration_reward, do: [click(:exploration_complete_claim_rewards), wait_until_arrived()]
  end

end
