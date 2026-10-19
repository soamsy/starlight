defmodule StarlightBot.Automation.Shop.Actions.BuyList do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def run(step, list, state, ctx) do
    max_items = step["max_items"] || 1

    case GiftPlans.list_remaining(list, owned_gifts(state, ctx)) do
      0 -> {:skipped, "list done: owns #{list["done_at"]} from #{list["name"]}", state}
      nil -> buy_from_shelf(list, max_items, state, ctx)
      remaining -> buy_from_shelf(list, min(max_items, remaining), state, ctx)
    end
  end

  defp buy_from_shelf(list, limit, state, ctx) do
    case Ops.shelf_items(ctx) do
      {:ok, items} ->
        items
        |> candidates(list["gifts"], state, ctx)
        |> Enum.take(limit)
        |> buy_all(0, state, ctx)

      {:error, reason} ->
        {:failed, "shelf scan failed: #{inspect(reason)}", state}
    end
  end

  defp owned_gifts(state, ctx) do
    ctx |> RunMemory.ego_gifts() |> Enum.map(fn {id, gift} -> state.gifts_by_id[id] || %{name: gift.name, tier: nil} end)
  end

  defp candidates(items, wanted, state, ctx) do
    owned = RunMemory.ego_gifts(ctx)

    items
    |> Enum.reject(&Map.has_key?(owned, &1.gift_id))
    |> Enum.uniq_by(& &1.gift_id)
    |> Enum.map(&{&1, GiftPlans.list_rank(wanted, state.gifts_by_id[&1.gift_id] || %{name: &1.gift_name, tier: nil})})
    |> Enum.reject(fn {_item, rank} -> is_nil(rank) end)
    |> Enum.sort_by(fn {_item, rank} -> rank end)
    |> Enum.map(fn {item, _rank} -> item end)
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
