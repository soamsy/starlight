defmodule StarlightBot.Automation.Shop.Actions.Uptie do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans

  def run(step, definitions, state, ctx) do
    case plan(step, definitions, state, ctx) do
      {[], reason} ->
        {:skipped, "nothing to uptie: #{reason}", state}

      {planned, reason} ->
        {outcome, detail} = uptie_all(planned, [], reason, ctx)
        Ops.recover_to_shop(ctx)
        {outcome, detail, state}
    end
  end

  defp uptie_all([], done, reason, _ctx), do: {:done, done_label(done) <> " (#{reason})"}

  defp uptie_all([item | rest], done, reason, ctx) do
    case Ops.uptie_gift(item.gift.id, item.from, item.to, ctx) do
      {:ok, level} when level == item.to ->
        RunMemory.set_ego_gift_uptie(ctx, item.gift.id, level)
        uptie_all(rest, done ++ ["#{item.gift.name} +#{level}"], reason, ctx)

      {:ok, level} ->
        RunMemory.set_ego_gift_uptie(ctx, item.gift.id, level)
        {:partial, done_label(done ++ ["#{item.gift.name} +#{level}"]) <> ", couldn't afford +#{item.to}, stopping"}

      {:error, failure} ->
        detail = "#{item.gift.name} +#{item.to} failed: #{inspect(failure)}"
        if done == [], do: {:failed, detail}, else: {:partial, done_label(done) <> ", then " <> detail}
    end
  end

  defp done_label(done), do: "uptied #{Enum.join(done, ", ")}"

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
