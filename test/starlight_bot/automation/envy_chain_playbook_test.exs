defmodule StarlightBot.Automation.EnvyChainPlaybookTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.SlotPlan
  alias StarlightBot.BattlePlans

  @enemies 4

  @envy_chain %{
    "id" => "pb_lhyxxry",
    "kind" => "focused",
    "name" => "EnvyChain",
    "actions" => [
      %{"id" => "ac_5gc3jfq", "type" => "win_rate"},
      %{
        "id" => "ac_fodpzwy",
        "type" => "nothing",
        "who" => "everyone",
        "sinners" => [],
        "skill" => %{"pick" => "last", "start" => 1, "end" => 1},
        "rest" => %{
          "type" => "target",
          "who" => "everyone",
          "where" => %{"join" => "and", "conditions" => [%{"kind" => "has", "values" => ["envy"]}, %{"kind" => "not_using", "values" => ["envy"]}]},
          "enemy" => %{"pick" => "last", "n" => 1, "step" => "left"},
          "row" => "priority",
          "priority" => %{"order" => ["envy", "s3", "s2", "s1"]},
          "sinners" => [],
          "skill" => %{"pick" => "all"},
          "rest" => %{
            "type" => "dodge",
            "who" => "everyone",
            "where" => %{"join" => "and", "conditions" => [%{"kind" => "has_no", "values" => ["envy"]}, %{"kind" => "top"}]},
            "enemy" => %{"pick" => "continue"},
            "sinners" => [],
            "skill" => %{"pick" => "all"},
            "rest" => %{
              "type" => "dodge",
              "who" => "everyone",
              "where" => %{"join" => "and", "conditions" => [%{"kind" => "has_no", "values" => ["envy"]}]},
              "enemy" => %{"pick" => "none"},
              "sinners" => [],
              "skill" => %{"pick" => "all"}
            }
          }
        }
      }
    ]
  }

  defp cell(sin, tier), do: %{sin: sin, tier: tier}

  defp tray(slots) do
    {Enum.map(slots, fn {top, _bottom} -> top end), Enum.map(slots, fn {_top, bottom} -> bottom end)}
  end

  defp holder_chain, do: Enum.find(@envy_chain["actions"], &(&1["type"] == "nothing"))

  defp env(slots, bottom_columns) do
    %{
      columns: Enum.to_list(0..(length(slots) - 1)),
      tray_groups: Enum.map(0..(length(slots) - 1), &[&1]),
      classified: tray(slots),
      bottom_columns: fn -> {:ok, bottom_columns} end,
      sinner_groups: fn _holder -> flunk("EnvyChain should not locate sinners") end
    }
  end

  defp resolve(slots, bottom_columns) do
    {steps, _notes} = SlotPlan.plan(holder_chain(), env(slots, bottom_columns))

    for step <- steps, step.action != "nothing" do
      %{action: step.action, column: step.column, row: step.row, enemy: enemy_slot(step.enemy)}
    end
  end

  defp enemy_slot(%{"pick" => "none"}), do: nil
  defp enemy_slot(enemy), do: BattlePlans.target_index(@enemies, enemy)

  describe "EnvyChain" do
    test "is a focused playbook that sets win rate and never commits itself" do
      assert @envy_chain["kind"] == "focused"
      assert Enum.map(@envy_chain["actions"], & &1["type"]) == ["win_rate", "nothing"]
    end

    test "mixed tray: leaves envy users and the last slot alone, drags envy in, dodges the rest" do
      slots = [
        {cell(:envy, :skill1), cell(:wrath, :skill1)},
        {cell(:wrath, :skill2), cell(:envy, :skill1)},
        {cell(:wrath, :skill3), cell(:envy, :skill2)},
        {cell(:pride, :skill1), cell(:lust, :skill1)},
        {cell(:pride, :skill2), cell(:gloom, :skill1)},
        {cell(:lust, :skill1), cell(:sloth, :skill2)},
        {cell(:wrath, :skill1), cell(:envy, :skill3)}
      ]

      win_rate_picked_bottom = [1, 3, 4]

      assert resolve(slots, win_rate_picked_bottom) == [
               %{action: "target", column: 2, row: :bottom, enemy: 3},
               %{action: "dodge", column: 5, enemy: 2, row: nil},
               %{action: "dodge", column: 3, enemy: nil, row: nil},
               %{action: "dodge", column: 4, enemy: nil, row: nil}
             ]
    end

    test "envy is dragged from whichever row holds it" do
      slots = [
        {cell(:envy, :skill2), cell(:wrath, :skill1)},
        {cell(:wrath, :skill1), cell(:envy, :skill3)},
        {cell(:pride, :skill1), cell(:pride, :skill1)}
      ]

      assert resolve(slots, [0]) == [
               %{action: "target", column: 0, row: :top, enemy: 3},
               %{action: "target", column: 1, row: :bottom, enemy: 2}
             ]
    end

    test "several envy slots fan out left across enemies, and later dodges continue the fan" do
      slots = [
        {cell(:wrath, :skill1), cell(:envy, :skill1)},
        {cell(:wrath, :skill1), cell(:envy, :skill1)},
        {cell(:pride, :skill1), cell(:lust, :skill1)},
        {cell(:pride, :skill1), cell(:lust, :skill1)}
      ]

      assert resolve(slots, []) == [
               %{action: "target", column: 0, row: :bottom, enemy: 3},
               %{action: "target", column: 1, row: :bottom, enemy: 2},
               %{action: "dodge", column: 2, enemy: 1, row: nil}
             ]
    end

    test "no envy anywhere: top slots dodge without a target because nothing continued" do
      slots = [
        {cell(:wrath, :skill1), cell(:lust, :skill1)},
        {cell(:pride, :skill1), cell(:lust, :skill1)},
        {cell(:sloth, :skill1), cell(:gloom, :skill1)}
      ]

      assert resolve(slots, [1]) == [
               %{action: "dodge", column: 0, enemy: nil, row: nil},
               %{action: "dodge", column: 1, enemy: nil, row: nil}
             ]
    end

    test "plan notes say what will happen and why" do
      slots = [
        {cell(:wrath, :skill3), cell(:envy, :skill2)},
        {cell(:lust, :skill1), cell(:sloth, :skill2)},
        {cell(:pride, :skill1), cell(:gloom, :skill1)}
      ]

      {_steps, notes} = SlotPlan.plan(holder_chain(), env(slots, []))

      assert notes == [
               "tray (top | bottom) 1: wrath/s3 | envy/s2, 2: lust/s1 | sloth/s2, 3: pride/s1 | gloom/s1",
               "everyone -> slot(s) 3",
               "bottom skill chosen in slot(s) []",
               "slots has envy and not using envy -> slot(s) 1",
               "rest takes slot(s) 1",
               "bottom skill chosen in slot(s) []",
               "slots has no envy and using top -> slot(s) 2",
               "rest takes slot(s) 2",
               "bottom skill chosen in slot(s) []",
               "slots has no envy -> no free slot(s) left",
               "slot 1 priority envy > s3 > s2 > s1: top wrath/s3, bottom envy/s2 -> bottom",
               "plan: slot 3 left alone",
               "plan: slot 1 bottom skill -> enemy 1 from last, then left (slot order 1)",
               "plan: slot 2 dodge -> enemy 1 from last, then left (slot order 2)"
             ]
    end

    test "everything already on envy: nothing is touched" do
      slots = [
        {cell(:envy, :skill1), cell(:wrath, :skill1)},
        {cell(:wrath, :skill1), cell(:envy, :skill2)},
        {cell(:envy, :skill3), cell(:wrath, :skill1)}
      ]

      assert resolve(slots, [1]) == []
    end
  end
end
