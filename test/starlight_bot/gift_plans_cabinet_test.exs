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
end
