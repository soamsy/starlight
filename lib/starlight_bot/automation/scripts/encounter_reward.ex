defmodule StarlightBot.Automation.Scripts.EncounterReward do
  import StarlightBot.Navigation.DSL

  @arrival_timeout 600_000

  def program, do: [await(:encounter_reward, timeout: @arrival_timeout), goto(:encounter_reward, :encounter_reward_over)]
end
