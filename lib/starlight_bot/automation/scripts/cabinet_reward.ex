defmodule StarlightBot.Automation.Scripts.CabinetReward do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.Scripts.RewardHelpers
  alias StarlightBot.Ctx

  @arrival_timeout 600_000
  @tier_hooks [:cabinet_reward_tier_3, :cabinet_reward_tier_2, :cabinet_reward_tier_1]

  def run(ctx \\ Ctx.new()) do
    with {:ok, _} <- Engine.act([await(:cabinet_reward, timeout: @arrival_timeout)], ctx),
         {:ok, _} <- RewardHelpers.select_best_available_gift(@tier_hooks, :cabinet_reward, ctx),
         {:ok, _} <- Engine.act([click(:cabinet_reward_select)], ctx),
         {:ok, _} <- RewardHelpers.dismiss_ego_gift_get(ctx) do
      {:ok, :cabinet_reward}
    end
  end
end
