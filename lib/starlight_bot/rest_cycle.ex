defmodule StarlightBot.RestCycle do
  alias StarlightBot.StarlightBudget

  @sinners StarlightBudget.max_free_sinners()
  @max_charge StarlightBudget.rest_per_free_sinner()

  def bonuses([]), do: []

  def bonuses(entries) do
    count = length(entries)
    keys = entries |> Enum.map(&identities/1) |> List.to_tuple()

    for index <- 0..(count - 1) do
      keys |> elem(index) |> Enum.map(&charge(keys, count, index, &1)) |> Enum.sum()
    end
  end

  defp identities(%{team: team, hook: hook, free: free}) do
    free = free |> max(0) |> min(@sinners)
    locked = for slot <- 1..(@sinners - free)//1, do: {:locked, team, slot}
    unlocked = for slot <- 1..free//1, do: {:free, team, hook, slot}
    MapSet.new(locked ++ unlocked)
  end

  defp charge(keys, count, index, identity) do
    steps = Enum.find(1..count, count, &MapSet.member?(elem(keys, Integer.mod(index - &1, count)), identity))
    min(steps - 1, @max_charge)
  end
end
