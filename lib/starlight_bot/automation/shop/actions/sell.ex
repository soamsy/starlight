defmodule StarlightBot.Automation.Shop.Actions.Sell do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def run(step, list, state, ctx) do
    case plan(step, list, state, ctx) do
      {:skip, reason} ->
        {:skipped, reason, state}

      {:sell, gifts, total, enough?} ->
        result = with_popup(state, ctx, fn -> sell_all(gifts, [], ctx) end)
        state = %{state | sell_popup_open: false}

        case result do
          {:ok, sold} when enough? -> {:done, sold_label(sold, total), state}
          {:ok, sold} -> {:partial, sold_label(sold, total) <> ", not enough to reach #{step["stop_at_cost"]}", state}
          {:error, [], failure} -> {:failed, failure, state}
          {:error, sold, failure} -> {:partial, sold_label(sold, nil) <> ", then " <> failure, state}
        end
    end
  end

  def preview(step, list, state, ctx) do
    case plan(step, list, state, ctx) do
      {:skip, reason} -> {:would_run, reason, state}
      {:sell, gifts, total, enough?} ->
        suffix = if enough?, do: "", else: ", not enough to reach #{step["stop_at_cost"]}"
        {:would_run, "would sell " <> Enum.map_join(gifts, ", ", &"#{&1.name} (#{&1.selling_cost})") <> " for #{total}#{suffix}", state}
    end
  end

  defp plan(step, list, state, ctx) do
    fodder = ctx |> RunMemory.ego_gifts() |> GiftPlans.fodder(state.protected, state.gifts_by_id)
    queue = if list, do: GiftPlans.list_sell_order(fodder, list["gifts"]), else: GiftPlans.sell_order(fodder, step["tiers"] || [])

    case needed(step, state, ctx) do
      :unknown_cost ->
        {:skip, "cost unknown, can't work out how much to sell"}

      needed when is_integer(needed) and needed <= 0 ->
        {:skip, "wallet already at #{step["stop_at_cost"]}"}

      needed ->
        case GiftPlans.sell_plan(queue, needed, step["max_items"] || 1) do
          {[], _total} -> {:skip, nothing_label(list)}
          {gifts, total} -> {:sell, gifts, total, is_nil(needed) or total >= needed}
        end
    end
  end

  defp nothing_label(nil), do: "nothing unprotected in those tiers"
  defp nothing_label(list), do: "nothing unprotected from #{list["name"]}"

  defp needed(%{"stop_at_cost" => stop}, state, ctx) when is_integer(stop) do
    case RunMemory.cost(ctx) do
      nil -> :unknown_cost
      cost -> stop - (cost - state.reserve)
    end
  end

  defp needed(_step, _state, _ctx), do: nil

  defp with_popup(state, ctx, fun) do
    opened = if state.sell_popup_open, do: {:ok, :already_open}, else: Ops.open_sell_popup(ctx)

    case opened do
      {:ok, _} ->
        result = fun.()
        Ops.close_sell_popup(ctx)
        result

      {:error, reason} ->
        {:error, [], "couldn't open the sell popup: #{inspect(reason)}"}
    end
  end

  defp sell_all([], sold, _ctx), do: {:ok, sold}

  defp sell_all([gift | rest], sold, ctx) do
    case Ops.sell_gift(gift.id, ctx) do
      :ok -> sell_all(rest, sold ++ [gift.name], ctx)
      {:error, reason} -> {:error, sold, "#{gift.name} failed: #{inspect(reason)}"}
    end
  end

  defp sold_label(sold, nil), do: "sold #{Enum.join(sold, ", ")}"
  defp sold_label(sold, total), do: "sold #{Enum.join(sold, ", ")} for #{total}"
end
