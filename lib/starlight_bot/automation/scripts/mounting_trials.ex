defmodule StarlightBot.Automation.Scripts.MountingTrials do
  import StarlightBot.Navigation.DSL
  alias StarlightBot.Navigation.Screens

  @arrival_timeout 600_000

  def program,
    do: [await_any(Screens.MountingTrials.selection_hooks(), timeout: @arrival_timeout), goto(:mounting_trials, :mounting_trials_over)]
end
