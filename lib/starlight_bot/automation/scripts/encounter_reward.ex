defmodule StarlightBot.Automation.Scripts.EncounterReward do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.Scripts.RewardHelpers
  alias StarlightBot.Ctx

  @arrival_timeout 600_000
  @default_location_timeout 10_000
  @priority_hooks [
    :encounter_reward_gain_cost,
    :encounter_reward_random_gift,
    :encounter_reward_starlight,
    :encounter_reward_resources
  ]

  def run(ctx \\ Ctx.new()) do
    with {:ok, _} <- Engine.act([await(:encounter_reward, timeout: @arrival_timeout)], ctx),
         :ok <- select_gift(ctx),
         {:ok, _} <- Engine.act([click(:encounter_reward_confirm)], ctx),
         {:ok, _} <- RewardHelpers.dismiss_ego_gift_get(ctx) do
      {:ok, :encounter_reward}
    end
  end

  defp select_gift(ctx) do
    case RewardHelpers.find_and_click_first(@priority_hooks, ctx) do
      {:ok, {:clicked, _rect}} ->
        :ok

      {:ok, :none} ->
        Ctx.log(ctx, :info, "no priority gift visible — retrying default location")
        select_default_location(ctx)

      {:error, _} = err ->
        err
    end
  end

  defp select_default_location(ctx) do
    case Engine.act(
           [
             retry_until(:encounter_reward_1_of_1, [click(:encounter_reward_default_location)],
               timeout: @default_location_timeout
             )
           ],
           ctx
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
