defmodule StarlightBot.Automation.Scripts.EncounterReward do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx

  @arrival_timeout 600_000

  def run(ctx \\ Ctx.new()) do
    with {:ok, _} <- Engine.act([await(:encounter_reward, timeout: @arrival_timeout)], ctx) do
      Engine.goto(:encounter_reward, :encounter_reward_over, ctx)
    end
  end
end
