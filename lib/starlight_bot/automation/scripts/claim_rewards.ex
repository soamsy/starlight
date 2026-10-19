defmodule StarlightBot.Automation.Scripts.ClaimRewards do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx

  @arrival_timeout 600_000
  @settle_check_ms 800

  def run(config, ctx \\ Ctx.new())

  def run(%{action: action} = config, ctx) when action in [:give_up, :to_window, :claim, :to_list] do
    weekly_bonus? = Map.get(config, :weekly_bonus?, true)

    with {:ok, _} <- await_entry(ctx),
         :ok <- ensure_on_reward_screen(ctx) do
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
    if Engine.check_within(:exploration_reward, @settle_check_ms) do
      :ok
    else
      Ctx.log(ctx, :info, "opening rewards popup")

      case Engine.goto(:exploration_complete, :exploration_reward, ctx) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp resolve_action(:claim, ctx) do
    if Engine.check_within(:exploration_reward_no_bp, @settle_check_ms) do
      Ctx.log(ctx, :info, "no rewards worth claiming — giving up instead")
      :give_up
    else
      :claim
    end
  end

  defp resolve_action(action, _ctx), do: action

  defp apply_action(:claim, weekly_bonus?, ctx) do
    with :ok <- maybe_disable_weekly_bonus(weekly_bonus?, ctx) do
      Ctx.log(ctx, :info, "claiming rewards")
      Engine.goto(:exploration_reward, :exploration_reward_claimed, ctx) |> tag(:claim)
    end
  end

  defp apply_action(:give_up, _weekly_bonus?, ctx) do
    Ctx.log(ctx, :info, "giving up rewards")
    Engine.goto(:exploration_reward, :give_up_rewards, ctx) |> tag(:give_up)
  end

  defp apply_action(:to_window, _weekly_bonus?, ctx) do
    if Engine.check_within(:exploration_reward_to_window, @settle_check_ms) do
      Ctx.log(ctx, :info, "heading to window, abandoning rewards")
      Engine.goto(:exploration_reward, :exploration_reward_to_window_done, ctx) |> tag(:to_window)
    else
      Ctx.log(ctx, :error, "exploration_reward_to_window not found — likely the wrong popup")
      {:error, :to_window_not_found}
    end
  end

  defp apply_action(:to_list, weekly_bonus?, ctx) do
    if Engine.check_within(:exploration_reward_to_list, @settle_check_ms) do
      Ctx.log(ctx, :info, "heading to list")
      Engine.goto(:exploration_reward, :exploration_reward_list, ctx) |> tag(:to_list)
    else
      Ctx.log(ctx, :info, "exploration_reward_to_list not found — giving up instead")
      apply_action(:give_up, weekly_bonus?, ctx)
    end
  end

  defp maybe_disable_weekly_bonus(true, _ctx), do: :ok

  defp maybe_disable_weekly_bonus(false, ctx) do
    Ctx.log(ctx, :info, "excluding weekly bonuses from this claim")

    case Engine.run_action(:exploration_reward, :disable_weekly_bonuses, ctx) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp tag({:ok, _}, action), do: {:ok, action}
  defp tag({:error, _} = err, _action), do: err
end
