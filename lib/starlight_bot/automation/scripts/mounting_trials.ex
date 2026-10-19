defmodule StarlightBot.Automation.Scripts.MountingTrials do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Automation.Engine
  alias StarlightBot.Ctx
  alias StarlightBot.Navigation.Screens

  @arrival_timeout 600_000

  def run(ctx \\ Ctx.new()) do
    with {:ok, _} <- Engine.act([await_any(Screens.MountingTrials.selection_hooks(), timeout: @arrival_timeout)], ctx) do
      Engine.goto(:mounting_trials, :mounting_trials_over, ctx)
    end
  end
end
