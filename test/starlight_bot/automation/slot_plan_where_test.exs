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
      %{"type" => "dodge", "who" => "before", "sinners" => ["faust"], "skill" => %{"pick" => "all"}, "enemy" => %{"pick" => "first", "offset" => 0, "step" => "right"}},
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

  defp has(values), do: %{"join" => "and", "conditions" => [%{"kind" => "has", "values" => values}]}

  defp with_defense(defense), do: Map.put(env([]), :defense_sins, fn -> defense end)

  defp where_columns(filter, defense) do
    {steps, _notes} = SlotPlan.plan(dodge(%{"where" => filter, "skip_bottom_target" => false}), with_defense(defense))
    Enum.map(steps, & &1.column)
  end

  test "has dodge+sin selects only slots whose sinner defends with that sin" do
    assert where_columns(has(["dodge+wrath"]), [:pride, :wrath, :wrath, nil]) == [1, 2]
    assert where_columns(has(["dodge+wrath", "dodge+pride"]), [:pride, :wrath, :lust, nil]) == [0, 1]
  end

  test "a bare dodge in has matches every slot" do
    assert where_columns(has(["dodge"]), [nil, nil, nil, nil]) == [0, 1, 2]
  end

  test "has no dodge+sin inverts the match" do
    filter = %{"join" => "and", "conditions" => [%{"kind" => "has", "values" => ["dodge+wrath"], "not" => true}]}
    assert where_columns(filter, [:pride, :wrath, :wrath, nil]) == [0]
  end

  test "has dodge+sin can mix with tier and sin chips" do
    assert where_columns(has(["dodge+lust", "gluttony"]), [nil, nil, :lust, nil]) == [2]
  end

  test "dodge skips the target on bottom-skill slots by default and does not spend a fan index on them" do
    assert columns(dodge(%{}), [1]) == [{0, "first", 0}, {1, "none", 1}, {2, "first", 1}]
  end

  test "dodge keeps targeting bottom-skill slots when the option is off" do
    assert columns(dodge(%{"skip_bottom_target" => false}), [1]) == [{0, "first", 0}, {1, "first", 1}, {2, "first", 2}]
  end

  defp target(row, extra) do
    Map.merge(
      %{"type" => "target", "who" => "before", "sinners" => ["faust"], "skill" => %{"pick" => "all"}, "enemy" => %{"pick" => "first", "offset" => 0, "step" => "right"}, "skip_bottom_target" => true, "row" => row},
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

  test "a continue entry with nothing before it leaves top and bottom skills alone but still dodges" do
    rest = fn order -> target("priority", %{"who" => "everyone", "sinners" => [], "enemy" => %{"pick" => "continue"}, "priority" => %{"order" => order}}) end

    {steps, notes} = SlotPlan.plan(rest.(["bottom"]), env([]))
    assert Enum.all?(steps, &(&1.action == "nothing"))
    assert Enum.any?(notes, &(&1 =~ "no enemy to continue from"))

    {steps, _notes} = SlotPlan.plan(rest.(["dodge"]), env([]))
    assert Enum.map(steps, &{&1.action, &1.row}) == List.duplicate({"target", :dodge}, 4)
  end

  test "a continue entry inherits the enemy of the entry before it" do
    first = target("bottom", %{"who" => "only", "sinners" => ["faust"], "enemy" => %{"pick" => "first", "offset" => 0, "step" => "right"}, "rest" => target("bottom", %{"who" => "everyone", "sinners" => [], "enemy" => %{"pick" => "continue"}})})
    {steps, _notes} = SlotPlan.plan(first, env([]))

    assert Enum.all?(steps, &(&1.action == "target"))
  end

  test "a continue entry whose predecessors took no slots inherits its parent's targeting rule" do
    rule = %{"pick" => "last", "offset" => 1, "step" => "left"}
    leaf = target("bottom", %{"who" => "everyone", "sinners" => [], "enemy" => %{"pick" => "continue"}})
    middle = target("bottom", %{"who" => "before", "sinners" => ["faust"], "enemy" => %{"pick" => "continue"}, "rest" => leaf})
    entry = target("bottom", %{"who" => "only", "sinners" => ["faust"], "enemy" => rule, "rest" => middle})
    env = Map.put(env([]), :sinner_groups, fn _holder -> :skip end)

    {steps, _notes} = SlotPlan.plan(entry, env)

    assert Enum.map(steps, &{&1.column, &1.action, &1.enemy["pick"], &1.enemy["index"]}) == [{0, "target", "last", 0}, {1, "target", "last", 1}, {2, "target", "last", 2}, {3, "target", "last", 3}]
  end

  test "a continue entry whose parent has no targeting rule either still leaves skill slots alone" do
    leaf = target("bottom", %{"who" => "everyone", "sinners" => [], "enemy" => %{"pick" => "continue"}})
    entry = target("bottom", %{"who" => "only", "sinners" => ["faust"], "enemy" => %{"pick" => "none"}, "rest" => leaf})
    env = Map.put(env([]), :sinner_groups, fn _holder -> :skip end)

    {steps, _notes} = SlotPlan.plan(entry, env)

    assert Enum.all?(steps, &(&1.action == "nothing"))
  end
end
