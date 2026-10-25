defmodule StarlightBot.Automation.Shop.Actions.Fusion do
  alias StarlightBot.Automation.Shop.Actions.{FixedFusion, TieredFusion}

  def obtain(%{fusion: %{"type" => "fixed"}} = entry, step, state, ctx, stack), do: FixedFusion.obtain(entry, step, state, ctx, stack)
  def obtain(entry, step, state, ctx, _stack), do: TieredFusion.obtain(entry, step, state, ctx)
end
