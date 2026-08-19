defmodule StarlightBot.Automation.Scripts do
  alias StarlightBot.Automation.Scripts.CabinetReward
  alias StarlightBot.Automation.Scripts.ChargeEnkephalin
  alias StarlightBot.Automation.Scripts.EncounterReward
  alias StarlightBot.Automation.Scripts.MirrorDungeonRunner
  alias StarlightBot.Automation.Scripts.MountingTrials
  alias StarlightBot.Automation.Scripts.ShopBuyer

  @scripts [
    %{name: :charge_enkephalin, label: "Charge Enkephalin", module: ChargeEnkephalin},
    %{name: :cabinet_reward, label: "Cabinet Reward", module: CabinetReward},
    %{name: :mounting_trials, label: "Mounting Trials", module: MountingTrials},
    %{name: :encounter_reward, label: "Encounter Reward", module: EncounterReward},
    %{name: :shop_buyer, label: "Shop Buyer", module: ShopBuyer},
    %{name: :mirror_dungeon, label: "Mirror Dungeon", module: MirrorDungeonRunner}
  ]

  @doc "All registered scripts, in declaration order."
  def all, do: @scripts

  @doc "Look up a registered script by name. Returns nil if not found."
  def find(name) when is_atom(name), do: Enum.find(@scripts, &(&1.name == name))
end
