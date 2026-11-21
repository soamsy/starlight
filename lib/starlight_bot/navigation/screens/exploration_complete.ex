defmodule StarlightBot.Navigation.Screens.ExplorationComplete do
  use StarlightBot.Navigation.DSL

  screen :exploration_complete, identity: :exploration_complete do
    transition to: :exploration_reward, do: confirm_enter(:exploration_complete_claim_rewards, rounds: 2, gone_hold: 50, gone_window: 1_000) ++ [attempt([wait_until_arrived()], else: loading())]
  end

end
