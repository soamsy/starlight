defmodule StarlightBot.Automation.SlotPlanWhereTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.SlotPlan

  defp cell(sin), do: %{sin: sin, tier: :skill1}

  defp env(bottom_columns) do
    slots = for sin <- ~w(wrath lust sloth gluttony)a, do: {cell(sin), cell(sin)}

    %{
      columns: [0, 1, 2, 3],
      tray_groups: [[0], [1], [2], [3]],
      classified: {Enum.map(slots, &elem(&1, 0)), Enum.map(slots, &elem(&1, 1))},
      bottom_columns: fn -> {:ok, bottom_columns} end,
      sinner_groups: fn _holder -> {:ok, [{[0], %{name: "A"}}, {[1], %{name: "B"}}, {[2], %{name: "C"}}]} end
    }
  end

  defp dodge(extra) do
    Map.merge(
      %{"type" => "dodge", "who" => "before", "sinners" => ["faust"], "skill" => %{"pick" => "all"}, "enemy" => %{"pick" => "first", "n" => 1, "step" => "right"}},
      extra
    )
  end

  defp columns(holder, bottom_columns) do
    {steps, _notes} = SlotPlan.plan(holder, env(bottom_columns))
    Enum.map(steps, &{&1.column, &1.enemy["pick"], &1.enemy["index"]})
  end

  test "where narrows a sinner selector to slots matching the filter" do
    top_only = dodge(%{"where" => %{"join" => "and", "conditions" => [%{"kind" => "top"}]}, "skip_bottom_target" => false})
    bottom_only = dodge(%{"where" => %{"join" => "and", "conditions" => [%{"kind" => "bottom"}]}, "skip_bottom_target" => false})

    assert columns(top_only, [1]) == [{0, "first", 0}, {2, "first", 1}]
    assert columns(bottom_only, [1]) == [{1, "first", 0}]
  end

  test "dodge skips the target on bottom-skill slots by default and does not spend a fan index on them" do
    assert columns(dodge(%{}), [1]) == [{0, "first", 0}, {1, "none", 1}, {2, "first", 1}]
  end

  test "dodge keeps targeting bottom-skill slots when the option is off" do
    assert columns(dodge(%{"skip_bottom_target" => false}), [1]) == [{0, "first", 0}, {1, "first", 1}, {2, "first", 2}]
  end

  defp target(row, extra) do
    Map.merge(
      %{"type" => "target", "who" => "before", "sinners" => ["faust"], "skill" => %{"pick" => "all"}, "enemy" => %{"pick" => "first", "n" => 1, "step" => "right"}, "skip_bottom_target" => true, "row" => row},
      extra
    )
  end

  test "target keeps the existing target only when the picked row is already the active one" do
    assert columns(target("top", %{}), [1]) == [{0, nil, nil}, {1, "first", 0}, {2, nil, nil}]
    assert columns(target("bottom", %{}), [1]) == [{0, "first", 0}, {1, nil, nil}, {2, "first", 1}]
  end

  test "target retargets everything when the option is off" do
    assert columns(target("top", %{"skip_bottom_target" => false}), [1]) == [{0, "first", 0}, {1, "first", 1}, {2, "first", 2}]
  end
end
