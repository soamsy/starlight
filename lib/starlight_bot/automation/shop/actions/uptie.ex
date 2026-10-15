defmodule StarlightBot.Automation.Shop.Actions.Uptie do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def run(step, definitions, state, ctx) do
    case plan(step, definitions, state, ctx) do
      {[], reason} ->
        {:skipped, "nothing to uptie: #{reason}", state}

      {[first | _], _reason} ->
        result = Ops.select_uptie_gift(first.gift.id, ctx)
        Ops.recover_to_shop(ctx)

        case result do
          :ok -> {:not_implemented, "selected #{first.gift.name} in the uptie popup; +1/+2 hooks aren't set up yet", state}
          {:error, reason} -> {:failed, "couldn't select #{first.gift.name}: #{inspect(reason)}", state}
        end
    end
  end

  def preview(step, definitions, state, ctx) do
    case plan(step, definitions, state, ctx) do
      {[], reason} -> {:would_run, "nothing to uptie: #{reason}", state}
      {planned, reason} -> {:would_run, "would uptie " <> Enum.map_join(planned, ", ", &label/1) <> " (#{reason})", state}
    end
  end

  defp plan(step, definitions, state, ctx) do
    GiftPlans.uptie_plan(definitions, RunMemory.ego_gifts(ctx), state.gifts_by_name, RunMemory.cost(ctx), step["max_gifts"] || 1)
  end

  defp label(item), do: "#{item.gift.name} +#{item.from}→+#{item.to} (#{item.price})"
end
