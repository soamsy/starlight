defmodule StarlightBot.Automation.Shop.Actions.Fusion do
  alias StarlightBot.Automation.RunMemory
  alias StarlightBot.Automation.Shop.Actions.{FixedFusion, TieredFusion}
  alias StarlightBot.GiftPlans.FusionPlanner

  def run(step, definitions, state, ctx) do
    case FusionPlanner.current_fusion(definitions, owned_names(ctx)) do
      nil -> {:skipped, "every fusion target is owned", state}
      definition -> obtain(definition, step, state, ctx, [])
    end
  end

  def preview(_step, definitions, state, ctx) do
    case FusionPlanner.current_fusion(definitions, owned_names(ctx)) do
      nil -> {:skipped, "every fusion target is owned", state}
      %{"type" => "fixed"} = definition -> FixedFusion.preview(definition, state, ctx)
      definition -> TieredFusion.preview(definition, state, ctx)
    end
  end

  def obtain(%{"type" => "fixed"} = definition, step, state, ctx, stack), do: FixedFusion.obtain(definition, step, state, ctx, stack)
  def obtain(definition, step, state, ctx, _stack), do: TieredFusion.obtain(definition, step, state, ctx)

  defp owned_names(ctx), do: RunMemory.ego_gifts(ctx) |> Map.values() |> MapSet.new(& &1.name)
end
