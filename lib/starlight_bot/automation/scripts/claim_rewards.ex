defmodule StarlightBot.Automation.Scripts.ClaimRewards do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Navigation.{Catalog, Runner}

  @arrival_timeout 600_000
  @settle_check_ms 800

  def steps(%{action: action} = config) when action in [:give_up, :to_window, :claim, :to_list] do
    weekly_bonus? = Map.get(config, :weekly_bonus?, true)

    open_rewards = [log(:info, "opening rewards popup"), goto(:exploration_complete, :exploration_reward)]

    [
      log(:info, "waiting for exploration_complete or exploration_reward"),
      await_any([:exploration_complete, :exploration_reward], timeout: @arrival_timeout),
      branch([{:exploration_reward, []}, default: open_rewards], wait: @settle_check_ms)
    ] ++ action_steps(action, weekly_bonus?)
  end

  def steps(config), do: [log(:error, "invalid config #{inspect(config)}"), fail(:invalid_config)]

  defp action_steps(:claim, weekly_bonus?) do
    give_up = [log(:info, "no rewards worth claiming — giving up instead") | action_steps(:give_up, weekly_bonus?)]
    [branch([{:exploration_reward_no_bp, give_up}, default: claim_steps(weekly_bonus?)], wait: @settle_check_ms)]
  end

  defp action_steps(:give_up, _weekly_bonus?) do
    [log(:info, "giving up rewards"), goto(:exploration_reward, :give_up_rewards), result({:ok, :give_up})]
  end

  defp action_steps(:to_window, _weekly_bonus?) do
    to_window = [log(:info, "heading to window, abandoning rewards"), goto(:exploration_reward, :exploration_reward_to_window_done), result({:ok, :to_window})]
    not_found = [log(:error, "exploration_reward_to_window not found — likely the wrong popup"), fail(:to_window_not_found)]
    [branch([{:exploration_reward_to_window, to_window}, default: not_found], wait: @settle_check_ms)]
  end

  defp action_steps(:to_list, weekly_bonus?) do
    to_list = [log(:info, "heading to list"), goto(:exploration_reward, :exploration_reward_list), result({:ok, :to_list})]
    give_up = [log(:info, "exploration_reward_to_list not found — giving up instead") | action_steps(:give_up, weekly_bonus?)]
    [branch([{:exploration_reward_to_list, to_list}, default: give_up], wait: @settle_check_ms)]
  end

  defp claim_steps(weekly_bonus?) do
    disable_weekly_bonus(weekly_bonus?) ++
      [log(:info, "claiming rewards"), goto(:exploration_reward, :exploration_reward_claimed), result({:ok, :claim})]
  end

  defp disable_weekly_bonus(true), do: []

  defp disable_weekly_bonus(false) do
    action = Catalog.find_action(:exploration_reward, :disable_weekly_bonuses)
    [log(:info, "excluding weekly bonuses from this claim") | Runner.action_program(:exploration_reward, action)]
  end
end
