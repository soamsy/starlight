defmodule StarlightBot.GiftPlansCabinetTest do
  use ExUnit.Case, async: true

  alias StarlightBot.GiftPlans

  test "cabinet order keeps the plan's picks for the current affinity and fills in the rest" do
    assert GiftPlans.cabinet_order(%{"affinity" => "sinking", "cabinet_gifts" => ["Grandeur", "Stone Tomb"]}) ==
             ["Grandeur", "Red Order", "Melted Spring"]

    assert GiftPlans.cabinet_order(%{"affinity" => nil, "cabinet_gifts" => ["Grandeur"]}) == []
    assert GiftPlans.blank("slash")["cabinet_gifts"] == GiftPlans.starting_gifts("slash")
  end

  test "cabinet slots are each gift's position in the affinity's list" do
    assert GiftPlans.cabinet_slots(%{"affinity" => "sinking", "cabinet_gifts" => ["Grandeur", "Melted Spring", "Red Order"]}) == [2, 1, 0]
    assert GiftPlans.cabinet_slots(%{"affinity" => "sinking", "cabinet_gifts" => []}) == [0, 1, 2]
    assert GiftPlans.cabinet_slots(%{"affinity" => nil}) == [0, 1, 2]
  end

  test "perfected priority defaults to every option, honors order and drops unprioritized ones" do
    options = ["A", "B", "C"]
    data = %{"grace_picks" => [%{"index" => 0, "enhance" => 0}, %{"index" => 9, "enhance" => 1}]}
    assert GiftPlans.perfected_priority(data, options) == ["A", "B", "C"]
    assert GiftPlans.perfected_target(data, options) == "A"
    refute GiftPlans.restart_without_target?(data, options)

    data = GiftPlans.set_perfected_priority(data, ["C", "A"], ["B"])
    assert GiftPlans.perfected_priority(data, options) == ["C", "A"]
    assert GiftPlans.perfected_unprioritized(data, options) == ["B"]
    assert GiftPlans.perfected_target(data, options) == "C"
    assert GiftPlans.perfected_pick(data)["enhance"] == 1

    data = GiftPlans.set_perfected_restart(data, true)
    assert GiftPlans.restart_without_target?(data, options)

    data = GiftPlans.set_perfected_priority(data, [], ["A", "B", "C"])
    assert GiftPlans.perfected_target(data, options) == nil
    refute GiftPlans.restart_without_target?(data, options)

    assert GiftPlans.perfected_target(%{"grace_picks" => []}, options) == nil
  end

  test "perfected target options are tier 3 gifts of the affinity that no theme pack owns" do
    gifts = [
      %{id: "1", name: "A", tier: 3, affinity: "burn"},
      %{id: "2", name: "B", tier: 3, affinity: "burn"},
      %{id: "3", name: "C", tier: 2, affinity: "burn"},
      %{id: "4", name: "D", tier: 3, affinity: "slash"}
    ]

    assert GiftPlans.perfected_target_options(gifts, %{"2" => ["Pack"]}, "burn") == ["A"]
  end
end
