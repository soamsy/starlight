defmodule StarlightBot.Automation.Scripts.SelectTeamGloom do
  alias StarlightBot.Automation.Scripts.SelectTeam
  alias StarlightBot.Ctx

  def run(ctx \\ Ctx.new()), do: SelectTeam.run(:gloom, ctx)
end
