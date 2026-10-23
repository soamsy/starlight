defmodule StarlightBot.Automation.Scripts.CabinetReward do
  import StarlightBot.Navigation.DSL

  @arrival_timeout 600_000

  def program, do: [await(:cabinet_reward, timeout: @arrival_timeout), goto(:cabinet_reward, :cabinet_reward_over)]
end
