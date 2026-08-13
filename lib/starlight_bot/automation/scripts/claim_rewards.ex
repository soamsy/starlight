defmodule StarlightBot.Automation.Scripts.ClaimRewards do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx

  @arrival_timeout 600_000
  @popup_timeout 10_000
  @confirm_timeout 10_000
  @acquired_timeout 5_000

  def run(config, ctx \\ Ctx.new())

  def run(%{action: action} = config, ctx) when action in [:give_up, :to_window, :claim, :to_list] do
    weekly_bonus? = Map.get(config, :weekly_bonus?, true)

    with {:ok, _} <- await_entry(ctx),
         {:ok, _} <- ensure_on_reward_screen(ctx) do
      apply_action(resolve_action(action, ctx), weekly_bonus?, ctx)
    end
  end

  def run(config, ctx) do
    Ctx.log(ctx, :error, "invalid config #{inspect(config)}")
    {:error, :invalid_config}
  end

  defp await_entry(ctx) do
    Ctx.log(ctx, :info, "waiting for exploration_complete or exploration_reward")
    Engine.act([await_any([:exploration_complete, :exploration_reward], timeout: @arrival_timeout)], ctx)
  end

  defp ensure_on_reward_screen(ctx) do
    if Engine.check(:exploration_reward) do
      {:ok, nil}
    else
      Ctx.log(ctx, :info, "opening rewards popup")

      Engine.act(
        [click(:exploration_complete_claim_rewards), await(:exploration_reward, timeout: @popup_timeout)],
        ctx
      )
    end
  end

  defp resolve_action(:claim, ctx) do
    if Engine.check(:exploration_reward_no_bp) do
      Ctx.log(ctx, :info, "no rewards worth claiming — giving up instead")
      :give_up
    else
      :claim
    end
  end

  defp resolve_action(action, _ctx), do: action

  defp apply_action(:give_up, _weekly_bonus?, ctx) do
    Ctx.log(ctx, :info, "giving up rewards")

    ([click(:exploration_reward_give_up)] ++
       confirm_either(:exploration_reward_give_up_confirm, :exploration_reward_give_up_confirm_2))
    |> Engine.act(ctx)
    |> tag(:give_up)
  end

  defp apply_action(:to_window, _weekly_bonus?, ctx) do
    if Engine.check(:exploration_reward_to_window) do
      Ctx.log(ctx, :info, "heading to window, abandoning rewards")

      ([
         click(:exploration_reward_to_window),
         await(:exploration_reward_to_window_confirm, timeout: @confirm_timeout),
         click(:exploration_reward_to_window_confirm)
       ] ++ loading())
      |> Engine.act(ctx)
      |> tag(:to_window)
    else
      Ctx.log(ctx, :error, "exploration_reward_to_window not found — likely the wrong popup")
      {:error, :to_window_not_found}
    end
  end

  defp apply_action(:to_list, weekly_bonus?, ctx) do
    if Engine.check(:exploration_reward_to_list) do
      Ctx.log(ctx, :info, "heading to list")

      case Engine.act([click(:exploration_reward_to_list)], ctx) do
        {:ok, _} -> {:ok, :to_list}
        {:error, _} = err -> err
      end
    else
      Ctx.log(ctx, :info, "exploration_reward_to_list not found — giving up instead")
      apply_action(:give_up, weekly_bonus?, ctx)
    end
  end

  defp apply_action(:claim, weekly_bonus?, ctx) do
    with :ok <- maybe_disable_weekly_bonus(weekly_bonus?, ctx) do
      Ctx.log(ctx, :info, "claiming rewards")

      with {:ok, _} <-
             ([click(:exploration_reward_claim)] ++
                confirm_either(:exploration_reward_claim_confirm, :exploration_reward_claim_confirm_2))
             |> Engine.act(ctx),
           {:ok, _} <- maybe_click_acquired(ctx) do
        {:ok, :claim}
      end
    end
  end

  defp confirm_either(hook_a, hook_b) do
    [
      await_any([hook_a, hook_b], timeout: @confirm_timeout),
      branch([{hook_a, [click(hook_a)]}, {hook_b, [click(hook_b)]}])
    ]
  end

  defp maybe_click_acquired(ctx) do
    case Engine.act([await(:exploration_rewards_acquired, timeout: @acquired_timeout)], ctx) do
      {:ok, _} ->
        Engine.act([click(:exploration_rewards_acquired)], ctx)

      {:error, {:timeout, :exploration_rewards_acquired}} ->
        Ctx.log(ctx, :info, "exploration_rewards_acquired never appeared — assuming already done")
        {:ok, nil}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_disable_weekly_bonus(true, _ctx), do: :ok

  defp maybe_disable_weekly_bonus(false, ctx) do
    if Engine.check(:weekly_bonus_0_on) do
      Ctx.log(ctx, :info, "excluding weekly bonuses from this claim")

      case Engine.act([reclick_until_gone(:weekly_bonus_0_on)], ctx) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    else
      Ctx.log(ctx, :info, "weekly bonuses already off / unavailable — nothing to do")
      :ok
    end
  end

  defp tag({:ok, _}, action), do: {:ok, action}
  defp tag({:error, _} = err, _action), do: err
end
