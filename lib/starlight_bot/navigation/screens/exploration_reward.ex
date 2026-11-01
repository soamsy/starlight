defmodule StarlightBot.Navigation.Screens.ExplorationReward do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine

  @confirm_timeout 4_000
  @second_confirm_timeout 3_000
  @acquired_timeout 4_000
  @weekly_bonus_hooks [:weekly_bonus_0_on, :weekly_bonus_1_on, :weekly_bonus_2_on]

  screen :exploration_reward, identity: :exploration_reward do
    action :disable_weekly_bonuses do
      Enum.map(@weekly_bonus_hooks, &branch([{&1, [reclick_until_gone(&1)]}, {:default, []}]))
    end

    transition to: :exploration_reward_claimed do
      [click(:exploration_reward_claim)] ++
        confirm_either(:exploration_reward_claim_confirm, :exploration_reward_claim_confirm_2, @confirm_timeout) ++
        [retry_until(any_of([:loading_stage_1, :loading_stage_2]), [click(:exploration_complete)], every: 300, timeout: 15_000)] ++
        loading()
    end

    transition to: :give_up_rewards do
      [
        click(:exploration_reward_give_up),
        branch(
          [
            {any_of([:exploration_reward_give_up_confirm, :exploration_reward_give_up_confirm_2]),
             confirm_either(:exploration_reward_give_up_confirm, :exploration_reward_give_up_confirm_2, @confirm_timeout)},
            {not_hook(:exploration_reward), []},
            default: []
          ],
          wait: @confirm_timeout
        ),
        wait_until(not_hook(:exploration_reward), timeout: 5_000)
      ]
    end

    transition to: :exploration_reward_to_window_done do
      [click(:exploration_reward_to_window)] ++
        confirm(:exploration_reward_to_window_confirm, timeout: @confirm_timeout) ++
        loading()
    end

    transition to: :exploration_reward_list, do: [click(:exploration_reward_to_list)]
  end

  screen :exploration_reward_claimed, identity: nil, catch_all: true
  screen :give_up_rewards, identity: nil, catch_all: true
  screen :exploration_reward_to_window_done, identity: nil, catch_all: true
  screen :exploration_reward_list, identity: nil, catch_all: true

  defp confirm_either(hook_a, hook_b, timeout) do
    confirm_enter(any_of([hook_a, hook_b]), timeout: timeout)
  end

  def confirm_again_and_acquire(_frame, ctx) do
    with {:ok, _} <- maybe_confirm_claim_again(ctx) do
      maybe_click_acquired(ctx)
    end
  end

  defp maybe_confirm_claim_again(ctx) do
    steps = confirm_either(:exploration_reward_claim_confirm, :exploration_reward_claim_confirm_2, @second_confirm_timeout)

    case Engine.act(steps, ctx) do
      {:ok, _} = ok -> ok
      {:error, {:timeout, _hooks}} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  defp maybe_click_acquired(ctx) do
    case Engine.act([await(:exploration_rewards_acquired, timeout: @acquired_timeout)], ctx) do
      {:ok, _} -> Engine.act([click(:exploration_rewards_acquired)], ctx)
      {:error, {:timeout, :exploration_rewards_acquired}} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end
end
