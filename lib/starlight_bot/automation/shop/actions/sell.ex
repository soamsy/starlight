defmodule StarlightBot.Automation.Shop.Actions.Sell do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def run(step, _definition, state, ctx) do
    if reached?(step, state, ctx) do
      {:skipped, "wallet already at #{step["stop_at_cost"]}", state}
    else
      step |> queue(state, ctx) |> sell_all(step, [], state, ctx)
    end
  end

  def preview(step, _definition, state, ctx) do
    case step |> queue(state, ctx) |> Enum.take(step["max_items"] || 1) do
      [] -> {:would_run, "nothing unprotected in those tiers", state}
      gifts -> {:would_run, "would sell up to " <> Enum.map_join(gifts, ", ", &"#{&1.name} (#{&1.selling_cost})"), state}
    end
  end

  defp queue(step, state, ctx) do
    ctx
    |> RunMemory.ego_gifts()
    |> GiftPlans.fodder(state.protected, state.gifts_by_id)
    |> GiftPlans.sell_order(step["tiers"] || [])
  end

  defp sell_all([], step, sold, state, _ctx) do
    cond do
      sold == [] -> {:skipped, "nothing unprotected in those tiers", state}
      is_nil(step["stop_at_cost"]) -> {:done, sold_label(sold), state}
      true -> {:partial, sold_label(sold) <> ", ran out before #{step["stop_at_cost"]}", state}
    end
  end

  defp sell_all([gift | rest], step, sold, state, ctx) do
    case Ops.sell_gift(gift.id, ctx) do
      :ok ->
        Ops.detect_and_update_cost(ctx)
        sold = sold ++ [gift.name]

        if length(sold) >= (step["max_items"] || 1) or reached?(step, state, ctx),
          do: {:done, sold_label(sold), state},
          else: sell_all(rest, step, sold, state, ctx)

      {:error, reason} ->
        {if(sold == [], do: :failed, else: :partial), sold_label(sold) <> ", then #{gift.name} failed: #{inspect(reason)}", state}
    end
  end

  defp reached?(%{"stop_at_cost" => stop}, state, ctx) when is_integer(stop) do
    case RunMemory.cost(ctx) do
      nil -> false
      cost -> cost - state.reserve >= stop
    end
  end

  defp reached?(_step, _state, _ctx), do: false

  defp sold_label([]), do: "sold nothing"
  defp sold_label(sold), do: "sold #{Enum.join(sold, ", ")}"
end
