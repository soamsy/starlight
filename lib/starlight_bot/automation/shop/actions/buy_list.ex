defmodule StarlightBot.Automation.Shop.Actions.BuyList do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops

  def run(step, list, state, ctx) do
    case Ops.shelf_items(ctx) do
      {:ok, items} ->
        items
        |> candidates(list["gifts"], ctx)
        |> Enum.take(step["max_items"] || 1)
        |> buy_all(0, state, ctx)

      {:error, reason} ->
        {:failed, "shelf scan failed: #{inspect(reason)}", state}
    end
  end

  defp candidates(items, wanted, ctx) do
    owned = RunMemory.ego_gifts(ctx)
    rank = wanted |> Enum.with_index() |> Map.new()

    items
    |> Enum.filter(&Map.has_key?(rank, &1.gift_name))
    |> Enum.reject(&Map.has_key?(owned, &1.gift_id))
    |> Enum.uniq_by(& &1.gift_id)
    |> Enum.sort_by(&rank[&1.gift_name])
  end

  defp buy_all([], 0, state, _ctx), do: {:skipped, "nothing from the list on the shelf", state}
  defp buy_all([], bought, state, _ctx), do: {:done, "bought #{bought}", state}

  defp buy_all([item | rest], bought, state, ctx) do
    case Ops.buy_item(item, ctx) do
      {:ok, :bought} -> buy_all(rest, bought + 1, state, ctx)
      {:ok, :insufficient_funds} -> stop(bought, "not enough cost for #{item.gift_name}", state)
      {:error, reason} -> stop(bought, inspect(reason), state)
    end
  end

  defp stop(0, reason, state), do: {:failed, reason, state}
  defp stop(bought, reason, state), do: {:partial, "bought #{bought}, then #{reason}", state}
end
