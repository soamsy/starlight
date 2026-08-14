defmodule StarlightBot.Navigation.Screens.EncounterReward do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.RewardHelpers
  alias StarlightBot.Ctx

  @default_location_timeout 2_000
  @priority_hooks [
    :encounter_reward_gain_cost,
    :encounter_reward_random_gift,
    :encounter_reward_starlight,
    :encounter_reward_resources
  ]

  screen :encounter_reward, identity: :encounter_reward do
    transition to: :encounter_reward_over do
      [
        custom(&select_priority_gift/2),
        click(:encounter_reward_confirm),
        RewardHelpers.dismiss_ego_gift_get_step()
      ]
    end
  end

  screen :encounter_reward_over, identity: nil, catch_all: true

  def select_priority_gift(_frame, ctx) do
    case RewardHelpers.find_and_click_first(@priority_hooks, ctx) do
      {:ok, {:clicked, _rect}} ->
        {:ok, nil}

      {:ok, :none} ->
        Ctx.log(ctx, :info, "no priority gift visible — retrying default location")

        Engine.act(
          [retry_until(:encounter_reward_1_of_1, [click(:encounter_reward_default_location)], timeout: @default_location_timeout)],
          ctx
        )

      {:error, _} = err ->
        err
    end
  end
end
