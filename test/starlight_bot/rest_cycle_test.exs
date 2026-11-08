defmodule StarlightBot.RestCycleTest do
  use ExUnit.Case, async: true

  alias StarlightBot.RestCycle

  defp entry(team, hook, free), do: %{team: team, hook: hook, free: free}

  test "one team repeated has no rest bonus" do
    assert RestCycle.bonuses([entry(1, "a", 5)]) == [0]
  end

  test "two different teams rest one run each" do
    assert RestCycle.bonuses([entry(1, "a", 5), entry(2, "a", 5)]) == [12, 12]
  end

  test "six different teams hit the cap" do
    assert RestCycle.bonuses(for(team <- 1..6, do: entry(team, "a", 5))) == List.duplicate(60, 6)
  end

  test "one team with six hooks only rests its free sinners" do
    assert RestCycle.bonuses(for(hook <- ~w(a b c d e f), do: entry(1, hook, 5))) == List.duplicate(25, 6)
  end

  test "team a once and team b with five hooks" do
    entries = [entry(1, "a", 5)] ++ for(hook <- ~w(a b c d e), do: entry(2, hook, 5))
    assert RestCycle.bonuses(entries) == [60, 32, 25, 25, 25, 25]
  end

  test "same team and hook twice depletes each other" do
    assert RestCycle.bonuses([entry(1, "a", 5), entry(1, "a", 5)]) == [0, 0]
  end

  test "empty cycle" do
    assert RestCycle.bonuses([]) == []
  end
end
