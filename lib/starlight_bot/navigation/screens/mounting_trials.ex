defmodule StarlightBot.Navigation.Screens.MountingTrials do
  use StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Automation.RewardHelpers

  @pick_delay_ms 400
  @tier_hooks [:mounting_trials_tier_4, :mounting_trials_tier_3, :mounting_trials_tier_2, :mounting_trials_tier_1]

  screen :mounting_trials, identity: :mounting_trials do
    transition to: :mounting_trials_over, do: [custom(&select_and_confirm_gifts/2)]
  end

  screen :mounting_trials_over, identity: nil, catch_all: true

  def select_and_confirm_gifts(_frame, ctx) do
    count = if Engine.check(:mounting_trials_0_of_2), do: 2, else: 1

    with :ok <- select_gifts(count, ctx),
         {:ok, _} <- Engine.act([click(confirm_hook(count))], ctx) do
      dismiss_all_ego_gifts(count, ctx)
    end
  end

  defp confirm_hook(1), do: :mounting_trials_1_of_1
  defp confirm_hook(2), do: :mounting_trials_2_of_2

  defp select_gifts(count, ctx) do
    1..count
    |> Enum.reduce_while({:ok, []}, fn _i, {:ok, clicked} ->
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
    Enum.reduce_while(1..count, {:ok, nil}, fn _i, {:ok, _} ->
      case RewardHelpers.dismiss_ego_gift_get(ctx) do
        {:ok, _} = ok -> {:cont, ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
