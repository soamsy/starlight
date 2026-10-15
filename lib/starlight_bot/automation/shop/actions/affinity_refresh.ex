defmodule StarlightBot.Automation.Shop.Actions.AffinityRefresh do
  alias StarlightBot.Automation.Shop.Ops

  def run(step, _definition, state, ctx) do
    case step["affinity"] || state.plan["affinity"] do
      nil ->
        {:failed, "no affinity set on the step or the plan", state}

      affinity ->
        case Ops.keyword_refresh(affinity, ctx) do
          :ok -> {:done, "refreshed for #{affinity}", state}
          {:error, reason} -> {:failed, inspect(reason), state}
        end
    end
  end
end
