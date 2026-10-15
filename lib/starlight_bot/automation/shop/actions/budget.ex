defmodule StarlightBot.Automation.Shop.Actions.Budget do
  def run(step, _definition, state, _ctx) do
    reserve = state.reserve + (step["amount"] || 0)
    {:done, "reserve now #{reserve}", %{state | reserve: reserve}}
  end
end
