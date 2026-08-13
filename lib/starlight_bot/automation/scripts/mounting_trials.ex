defmodule StarlightBot.Automation.Scripts.MountingTrials do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.Scripts.RewardHelpers
  alias StarlightBot.Ctx

  @arrival_timeout 600_000
  @pick_delay_ms 400
  @tier_hooks [:mounting_trials_tier_3, :mounting_trials_tier_2, :mounting_trials_tier_1]

  def run(ctx \\ Ctx.new()) do
    with {:ok, gift_count} <- await_entry_and_count(ctx),
         :ok <- select_gifts(gift_count, ctx),
         {:ok, _} <- Engine.act([click(confirm_hook(gift_count))], ctx),
         :ok <- dismiss_all_ego_gifts(gift_count, ctx) do
      {:ok, :mounting_trials}
    end
  end

  defp await_entry_and_count(ctx) do
    case Engine.act(
           [await_any([:mounting_trials_0_of_1, :mounting_trials_0_of_2], timeout: @arrival_timeout)],
           ctx
         ) do
      {:ok, _} ->
        if Engine.check(:mounting_trials_0_of_2), do: {:ok, 2}, else: {:ok, 1}

      {:error, _} = err ->
        err
    end
  end

  defp confirm_hook(1), do: :mounting_trials_1_of_1
  defp confirm_hook(2), do: :mounting_trials_2_of_2

  defp select_gifts(count, ctx) do
    Enum.reduce_while(1..count, {:ok, []}, fn _i, {:ok, clicked} ->
      case RewardHelpers.select_best_available_gift(@tier_hooks, :mounting_trials, ctx, exclude: clicked) do
        {:ok, {:clicked, rect}} ->
          Process.sleep(@pick_delay_ms)
          {:cont, {:ok, [rect | clicked]}}

        {:ok, :fallback} ->
          Process.sleep(@pick_delay_ms)
          {:cont, {:ok, clicked}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, _clicked} -> :ok
      {:error, _} = err -> err
    end
  end

  defp dismiss_all_ego_gifts(count, ctx) do
    Enum.reduce_while(1..count, :ok, fn _i, :ok ->
      case RewardHelpers.dismiss_ego_gift_get(ctx) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
