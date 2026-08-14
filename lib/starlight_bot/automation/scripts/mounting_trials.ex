defmodule StarlightBot.Automation.Scripts.MountingTrials do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx

  @arrival_timeout 600_000

  def run(ctx \\ Ctx.new()) do
    with {:ok, _} <- Engine.act([await_any([:mounting_trials_0_of_1, :mounting_trials_0_of_2], timeout: @arrival_timeout)], ctx) do
      Engine.goto(:mounting_trials, :mounting_trials_over, ctx)
    end
  end
end
