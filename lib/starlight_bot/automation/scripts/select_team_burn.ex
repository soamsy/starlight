defmodule StarlightBot.Automation.Scripts.SelectTeamBurn do
  alias StarlightBot.Automation.Scripts.SelectTeam
  alias StarlightBot.Ctx

  def run(ctx \\ Ctx.new()), do: SelectTeam.run(:burn, ctx)
end
