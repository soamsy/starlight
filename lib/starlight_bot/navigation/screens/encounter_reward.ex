defmodule StarlightBot.Navigation.Screens.EncounterReward do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.RewardHelpers
  alias StarlightBot.Ctx

  @default_location_timeout 1_000
  @ready_wait_ms 2_000
  @ready_settle_ms 100
  @close_timeout_ms 8_000
  @close_poll_ms 100
  @gift_popup_grace_ms 300
  @priority_hooks [
    :encounter_reward_gain_cost,
    :encounter_reward_random_gift,
    :encounter_reward_starlight,
    :encounter_reward_resources
  ]

  screen :encounter_reward, identity: :encounter_reward do
    transition to: :encounter_reward_over do
      [
        branch([{any_of(@priority_hooks), [sleep(@ready_settle_ms)]}], wait: @ready_wait_ms),
        custom(&select_priority_gift/2),
        click(:encounter_reward_confirm),
        custom(&await_reward_closed/2)
      ]
    end
  end

  screen :encounter_reward_over, identity: nil, catch_all: true

  def await_reward_closed(_frame, ctx), do: poll_reward_closed(ctx, System.monotonic_time(:millisecond) + @close_timeout_ms)

  defp poll_reward_closed(ctx, deadline) do
    cond do
      Engine.check(:ego_gift_get) ->
        collect_ego_gift(ctx)

      Engine.check(:encounter_reward_0_of_1) ->
        {:ok, nil}

      Engine.check(not_hook(:encounter_reward)) ->
        if Engine.check_within(:ego_gift_get, @gift_popup_grace_ms), do: collect_ego_gift(ctx), else: {:ok, nil}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :encounter_reward_not_closed}

      true ->
        Process.sleep(@close_poll_ms)
        poll_reward_closed(ctx, deadline)
    end
  end

  defp collect_ego_gift(ctx) do
    Ctx.log(ctx, :info, "encounter reward gave an EGO gift, dismissing it")

    with {:ok, _} <- RewardHelpers.record_ego_gift_items(nil, ctx),
         {:ok, _} <- RewardHelpers.dismiss_ego_gift_get(ctx, leaving: :encounter_reward) do
      {:ok, nil}
    end
  end

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
