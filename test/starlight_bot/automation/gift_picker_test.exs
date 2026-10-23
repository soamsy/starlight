defmodule StarlightBot.Automation.GiftPickerTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.{GiftPicker, RewardHelpers}

  defp det(id, name, cx, cy, conf), do: %{gift_id: id, gift_name: name, x: cx - 40, y: cy - 40, w: 80, h: 80, classifier_confidence: conf}

  @gifts %{
    "g_t3a" => %{tier: 3},
    "g_t3b" => %{tier: 3},
    "g_t2" => %{tier: 2},
    "g_t4" => %{tier: 4}
  }

  test "two detections in one 350x250 slot collapse to the more confident one" do
    slots = GiftPicker.slots([det("g_t2", "Low", 500, 400, 0.6), det("g_t3a", "High", 530, 420, 0.95), det("g_t3b", "Next", 860, 400, 0.9)])

    assert Enum.map(slots, & &1.gift_name) == ["High", "Next"]
    assert hd(slots).rect == {355, 295, 350, 250}
  end

  test "neighbors a little closer than a slot width still count as separate gifts" do
    slots = GiftPicker.slots([det("g_t3a", "A", 500, 400, 0.9), det("g_t3b", "B", 650, 400, 0.9)])
    assert length(slots) == 2
  end

  test "higher tier first, then wanted and unowned in plan order, then unowned, then owned" do
    slots =
      GiftPicker.slots([
        det("g_t4", "Owned T4", 100, 400, 0.9),
        det("g_t2", "Wanted T2", 500, 400, 0.9),
        det("g_t3b", "Wanted T3 late", 900, 400, 0.9),
        det("g_t3a", "Wanted T3 early", 1300, 400, 0.9)
      ])

    wanted = ["Wanted T3 early", "Wanted T2", "Wanted T3 late", "Owned T4"]
    owned = %{"g_t4" => %{name: "Owned T4"}}

    assert GiftPicker.rank(slots, wanted, owned, @gifts) |> Enum.map(& &1.gift_name) ==
             ["Owned T4", "Wanted T3 early", "Wanted T3 late", "Wanted T2"]

    assert GiftPicker.rank(slots, [], %{}, @gifts) |> Enum.map(& &1.gift_name) ==
             ["Owned T4", "Wanted T3 late", "Wanted T3 early", "Wanted T2"]
  end

  test "within a tier, a wanted gift beats an unwanted one and an owned one comes last" do
    slots =
      GiftPicker.slots([
        det("g_t3a", "Owned T3", 100, 400, 0.9),
        det("g_t3b", "Plain T3", 500, 400, 0.9),
        det("g_t2", "Wanted T2", 900, 400, 0.9),
        det("g_t3c", "Wanted T3", 1300, 400, 0.9)
      ])

    gifts = Map.put(@gifts, "g_t3c", %{tier: 3})
    owned = %{"g_t3a" => %{name: "Owned T3"}}

    assert GiftPicker.rank(slots, ["Wanted T2", "Wanted T3", "Owned T3"], owned, gifts) |> Enum.map(& &1.gift_name) ==
             ["Wanted T3", "Plain T3", "Owned T3", "Wanted T2"]
  end

  test "a tier badge inside a picked slot counts as already clicked" do
    slot_rect = {355, 295, 350, 250}
    assert RewardHelpers.already_clicked?({600, 500, 40, 30}, [slot_rect])
    refute RewardHelpers.already_clicked?({900, 500, 40, 30}, [slot_rect])
    assert RewardHelpers.already_clicked?({100, 100, 20, 20}, [{95, 95, 20, 20}])
  end

  test "tier badges fill gaps the gift detector left, highest tier first, but never a slot it already took" do
    named = GiftPicker.slots([det("g_t2", "Seen T2", 500, 400, 0.9)])

    badges = [
      {4, {880, 380, 30, 30}},
      {3, {890, 385, 30, 30}},
      {3, {520, 380, 30, 30}},
      {2, {1280, 380, 30, 30}}
    ]

    assert [%{tier: 4, gift_id: nil, center: {895.0, 395.0}}, %{tier: 2}] = GiftPicker.badge_slots(named, badges)
  end

  test "a badge-only gift outranks a detected gift of a lower tier" do
    named = GiftPicker.slots([det("g_t3a", "Wanted T3", 500, 400, 0.9)])
    filled = GiftPicker.badge_slots(named, [{4, {880, 380, 30, 30}}])

    assert [%{tier: 4}, %{gift_name: "Wanted T3"}] = GiftPicker.rank(named ++ filled, ["Wanted T3"], %{}, @gifts)
  end

  test "enemy HP badges attach to the gift above them by x, and unmatched gifts are 0%" do
    slots = GiftPicker.slots([det("g_t3a", "A", 400, 360, 0.9), det("g_t3b", "B", 800, 360, 0.9), det("g_t2", "C", 1200, 360, 0.9)])
    gates = [{380, 745, 78, 31}, {780, 745, 78, 31}, {1180, 745, 78, 31}]
    with_hp = GiftPicker.assign_hp(slots, [{5, {410, 760, 40, 28}}, {7.5, {1190, 760, 40, 28}}, {2.5, {1700, 760, 40, 28}}], gates)

    assert Enum.map(with_hp, &{&1.gift_name, &1.hp}) == [{"A", 5}, {"B", 0}, {"C", 7.5}]
  end

  test "the max HP text alone means at least 2.5%, and a percentage badge next to it raises it" do
    slots = GiftPicker.slots([det("g_t3a", "A", 400, 360, 0.9), det("g_t3b", "B", 800, 360, 0.9)])
    gates = [{380, 745, 78, 31}, {780, 745, 78, 31}]
    with_hp = GiftPicker.assign_hp(slots, [{2.5, {380, 745, 78, 31}}, {2.5, {780, 745, 78, 31}}, {5, {830, 760, 40, 28}}], gates)

    assert Enum.map(with_hp, &{&1.gift_name, &1.hp}) == [{"A", 2.5}, {"B", 5}]
  end

  test "percentage badges on a gift without the max HP text don't count as enemy HP" do
    slots = GiftPicker.slots([det("g_t3a", "A", 400, 360, 0.9), det("g_t3b", "B", 800, 360, 0.9)])
    with_hp = GiftPicker.assign_hp(slots, [{2.5, {380, 745, 78, 31}}, {10, {430, 760, 40, 28}}, {10, {830, 760, 40, 28}}], [{380, 745, 78, 31}])

    assert Enum.map(with_hp, &{&1.gift_name, &1.hp}) == [{"A", 10}, {"B", 0}]
  end

  test "avoiding enemy HP goes 0%, then 2.5%, then 5%, then 7.5%, tier order within each" do
    ranked = [
      %{gift_name: "T4 +7.5", hp: 7.5},
      %{gift_name: "T3 +5", hp: 5},
      %{gift_name: "T3 +2.5", hp: 2.5},
      %{gift_name: "T2 +0", hp: 0}
    ]

    assert GiftPicker.avoid_hp(ranked) |> Enum.map(& &1.gift_name) == ["T2 +0", "T3 +2.5", "T3 +5", "T4 +7.5"]
  end
end
