defmodule StarlightBot.Automation.Scripts do
  alias StarlightBot.Automation.Scripts.ChargeEnkephalin
  alias StarlightBot.Automation.Scripts.SelectTeamBurn
  alias StarlightBot.Automation.Scripts.SelectTeamGloom

  @scripts [
    %{name: :charge_enkephalin, label: "Charge Enkephalin", module: ChargeEnkephalin},
    %{name: :select_team_burn, label: "Select Team: Burn", module: SelectTeamBurn},
    %{name: :select_team_gloom, label: "Select Team: Gloom", module: SelectTeamGloom}
  ]

  @doc "All registered scripts, in declaration order."
  def all, do: @scripts

  @doc "Look up a registered script by name. Returns nil if not found."
  def find(name) when is_atom(name), do: Enum.find(@scripts, &(&1.name == name))
end
