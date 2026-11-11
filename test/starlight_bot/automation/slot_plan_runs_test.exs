defmodule StarlightBot.Automation.SlotPlanRunsTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.SlotPlan

  defp cells(sins), do: Enum.map(sins, &%{sin: &1, tier: :skill1})

  defp env(top, bottom, bottom_columns, extra \\ %{}) do
    count = length(top)

    Map.merge(
      %{
        columns: Enum.to_list(0..(count - 1)),
        tray_groups: Enum.map(0..(count - 1), &[&1]),
        classified: {cells(top), cells(bottom)},
        bottom_columns: fn -> {:ok, bottom_columns} end,
        sinner_groups: fn _holder -> {:ok, [{[1], %{name: "A"}}]} end,
        defense_sins: fn -> nil end
      },
      extra
    )
  end

  defp holder(mode, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "target",
        "who" => "everyone",
        "sinners" => [],
        "skill" => %{"pick" => "all"},
        "enemy" => %{"pick" => "none"},
        "skip_bottom_target" => true,
        "row" => "priority",
        "priority" => %{"order" => ["in_use"]},
        "mode" => mode
      },
      extra
    )
  end

  defp rows(holder, env) do
    {steps, notes} = SlotPlan.plan(holder, env)
    {Enum.map(steps, &{&1.column, &1.row}), notes}
  end

  test "a-res commits the slots of a 3-run and leaves the rest to the priority chips" do
    env = env([:wrath, :lust, :sloth, :gloom, :pride], [:lust, :lust, :lust, :envy, :envy], [])

    assert {[{0, :bottom}, {1, :top}, {2, :bottom}, {3, :top}, {4, :top}], notes} = rows(holder("a_res"), env)
    assert Enum.any?(notes, &(&1 =~ "a-res: runs of 3+ on slot(s) 1 bottom, 2 top, 3 bottom"))
  end

  test "with no 3-run reachable every slot keeps what is in use" do
    env = env([:wrath, :lust, :sloth, :gloom], [:pride, :envy, :wrath, :lust], [1])

    assert {[{0, :top}, {1, :bottom}, {2, :top}, {3, :top}], notes} = rows(holder("a_res"), env)
    assert Enum.any?(notes, &(&1 =~ "no run of 3+ reachable"))
  end

  test "a 2-run alone is not worth changing a slot" do
    env = env([:wrath, :gloom], [:lust, :wrath], [])

    assert {[{0, :top}, {1, :top}], _notes} = rows(holder("a_res"), env)
  end

  test "unselected slots count as they are now when looking for a run" do
    env = env([:lust, :gloom, :lust], [:envy, :lust, :pride], [])

    assert {[{1, :bottom}], _notes} = rows(holder("a_res", %{"who" => "only", "sinners" => ["faust"]}), env)
  end

  test "a-res+def uses a defense that completes a run and a-res alone does not" do
    env = env([:wrath, :gloom, :wrath], [:lust, :envy, :sloth], [], %{defense_sins: fn -> [nil, :wrath, nil] end})

    assert {[{0, :top}, {1, :dodge}, {2, :top}], _notes} = rows(holder("a_res_def"), env)
    assert {[{0, :top}, {1, :top}, {2, :top}], _notes} = rows(holder("a_res"), env)
  end

  test "the defense cap applies to this entry's slots" do
    env = env([:wrath, :gloom, :wrath], [:lust, :envy, :sloth], [], %{defense_sins: fn -> [nil, :wrath, nil] end})

    assert {[{0, :top}, {1, :top}, {2, :top}], _notes} = rows(holder("a_res_def", %{"max_defenses" => 0}), env)
  end

  test "an unreadable in-use state falls back to the priority chips" do
    env = env([:wrath, :lust, :sloth], [:lust, :lust, :lust], [], %{bottom_columns: fn -> :skip end})
    holder = holder("a_res", %{"priority" => %{"order" => ["in_use", "bottom"]}})

    assert {[{0, :bottom}, {1, :bottom}, {2, :bottom}], notes} = rows(holder, env)
    assert Enum.any?(notes, &(&1 =~ "can't read which skills are in use"))
  end

  test "the in use chip alone keeps the current row of each slot" do
    env = env([:wrath, :lust, :sloth], [:lust, :lust, :lust], [0, 2])

    assert {[{0, :bottom}, {1, :top}, {2, :bottom}], _notes} = rows(Map.delete(holder("none"), "mode"), env)
  end
end
