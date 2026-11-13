defmodule StarlightBot.RestCycleTest do
  use ExUnit.Case, async: true

  alias StarlightBot.RestCycle

  defp entry(team, hook, assigned \\ %{}), do: %{team: team, hook: hook, assigned: assigned}
  defp limits(entries), do: entries |> RestCycle.analyze() |> Enum.map(& &1.free_limit)

  test "one team repeated has no rest" do
    assert limits([entry(1, "a")]) == [0]
  end

  test "two different teams rest one run each" do
    assert limits([entry(1, "a"), entry(2, "a")]) == [12, 12]
  end

  test "six different teams hit the cap" do
    assert limits(for(team <- 1..6, do: entry(team, "a"))) == List.duplicate(60, 6)
  end

  test "one team with six hooks rests like six teams" do
    assert limits(for(hook <- ~w(a b c d e f), do: entry(1, hook))) == List.duplicate(60, 6)
  end

  test "free sinners are unique in every run, even for a repeated team and hook" do
    assert limits([entry(1, "a"), entry(1, "a")]) == [12, 12]
    assert limits([entry(1, "a"), entry(2, "a"), entry(1, "a")]) == [24, 24, 24]
  end

  test "assigned sinners rotate through their profiles per team and hook" do
    assigned = %{"yi_sang" => [10, 11, 12]}
    entries = [entry(1, "h1", assigned), entry(2, "h2"), entry(1, "h3", assigned), entry(1, "h4", assigned), entry(1, "h5", assigned)]
    rows = RestCycle.analyze(entries)

    yi_sang = fn row -> Enum.find(row.slots, &(&1.sinner == "yi_sang")) end
    assert Enum.map(rows, &Map.get(yi_sang.(&1), :profile_id)) == [10, nil, 11, 12, 10]
    assert Enum.map(rows, & &1.assigned_bonus) == [0, 0, 4, 4, 3]
    assert Enum.map(rows, & &1.free_count) == [11, 12, 11, 11, 11]
  end

  test "free sinners number their profiles per run they are free in" do
    [first, second] = RestCycle.analyze([entry(1, "a", %{"yi_sang" => [1]}), entry(2, "a")])
    assert Enum.map(first.slots, &(&1.kind == :free && &1.number)) |> Enum.reject(&(&1 == false)) == List.duplicate(1, 11)
    assert Enum.map(second.slots, & &1.number) == [1] ++ List.duplicate(2, 11)
  end

  test "estimate gives free sinners one rest per other team in the cycle" do
    assert Enum.map(1..6, &RestCycle.estimate(%{}, &1).free_charge) == [0, 1, 2, 3, 4, 5]
  end

  test "estimate averages assigned sinners over the cycle" do
    assigned = %{"yi_sang" => [1, 2, 3, 4], "faust" => [5, 6, 7], "ishmael" => [8, 9], "meursault" => [10]}
    estimate = RestCycle.estimate(assigned, 6)
    assert estimate.per_sinner == %{"yi_sang" => 3.0, "faust" => 2.0, "ishmael" => 1.0, "meursault" => 0.0}
    assert estimate.average == 6.0
  end

  test "empty cycle" do
    assert RestCycle.analyze([]) == []
  end
end
