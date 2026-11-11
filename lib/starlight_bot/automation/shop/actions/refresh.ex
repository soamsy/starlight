defmodule StarlightBot.Automation.Shop.Actions.Refresh do
  alias StarlightBot.Automation.Shop.Ops
  alias StarlightBot.GiftPlans.RefreshCosts

  def run(_step, _definition, state, ctx) do
    case Ops.refresh_shelf(ctx) do
      {:ok, _} -> {:done, "shelf refreshed (refresh #{state.refreshes + 1} this shop)", RefreshCosts.record(state, :normal)}
      {:error, reason} -> {:failed, inspect(reason), state}
    end
  end
end
