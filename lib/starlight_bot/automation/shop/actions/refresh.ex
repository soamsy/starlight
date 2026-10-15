defmodule StarlightBot.Automation.Shop.Actions.Refresh do
  alias StarlightBot.Automation.Shop.Ops

  def run(_step, _definition, state, ctx) do
    case Ops.refresh_shelf(ctx) do
      {:ok, _} -> {:done, "shelf refreshed", state}
      {:error, reason} -> {:failed, inspect(reason), state}
    end
  end
end
