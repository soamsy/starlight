defmodule StarlightBot.Automation.Shop.Actions.Sell do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def run_entries([], _entries, _keep, state, ctx), do: {[], false, close_popup(state, ctx)}

  def run_entries(sell_entries, entries, keep, state, ctx) do
    case plan(sell_entries, entries, keep, state, ctx) do
      [] ->
        {[], false, close_popup(state, ctx)}

      picks ->
        result = with_popup(state, ctx, fn -> sell_all(picks, [], ctx) end)
        state = %{state | sell_popup_open: false}

        case result do
          {:ok, sold} -> {[sold_label(sold)], true, count_sold(state, sold)}
          {:error, [], failure} -> {["sell: #{failure}"], false, state}
          {:error, sold, failure} -> {[sold_label(sold) <> ", then " <> failure], true, count_sold(state, sold)}
        end
    end
  end

  def plan(sell_entries, entries, keep, state, ctx) do
    order = sell_entries |> Enum.with_index() |> Map.new(fn {entry, index} -> {entry.id, index} end)

    ctx
    |> RunMemory.ego_gifts()
    |> GiftPlans.fodder(keep, state.gifts_by_id)
    |> Enum.flat_map(fn gift ->
      case GiftPlans.ruling_entry(entries, gift) do
        %{disposition: "sell"} = entry -> [{gift, entry}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {gift, entry} -> {order[entry.id], -gift.selling_cost, gift.name} end)
    |> Enum.reduce({[], Map.get(state, :sold, %{})}, fn {gift, entry}, {picked, counts} ->
      sold = Map.get(counts, entry.id, 0)

      if is_integer(entry.max) and sold >= entry.max,
        do: {picked, counts},
        else: {picked ++ [{gift, entry}], Map.put(counts, entry.id, sold + 1)}
    end)
    |> elem(0)
  end

  defp count_sold(state, sold) do
    counts = Enum.reduce(sold, Map.get(state, :sold, %{}), fn {_gift, entry}, counts -> Map.update(counts, entry.id, 1, &(&1 + 1)) end)
    Map.put(state, :sold, counts)
  end

  defp close_popup(%{sell_popup_open: true} = state, ctx) do
    Ops.close_sell_popup(ctx)
    %{state | sell_popup_open: false}
  end

  defp close_popup(state, _ctx), do: state

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

  defp sell_all([{gift, _entry} = pick | rest], sold, ctx) do
    case Ops.sell_gift(gift.id, ctx) do
      :ok -> sell_all(rest, sold ++ [pick], ctx)
      {:error, reason} -> {:error, sold, "#{gift.name} failed: #{inspect(reason)}"}
    end
  end

  defp sold_label(sold) do
    total = sold |> Enum.map(fn {gift, _entry} -> gift.selling_cost end) |> Enum.sum()
    "sold #{Enum.map_join(sold, ", ", fn {gift, _entry} -> gift.name end)} for #{total}"
  end
end
