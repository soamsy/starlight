defmodule StarlightBot.PlanIconsTest do
  use ExUnit.Case, async: true

  alias StarlightBot.{BattlePlans, PlanIcons}

  test "battle icons are the first three sinners of the first lineup" do
    lineup = %{BattlePlans.new_lineup("A") | "sinners" => ~w(faust yi_sang ryoshu gregor)}
    second = %{BattlePlans.new_lineup("B") | "sinners" => ~w(outis)}
    data = BattlePlans.blank() |> Map.put("lineups", [lineup, second])

    assert PlanIcons.icons(:battle_plans, data, nil) == ~w(/images/sinners/faust.webp /images/sinners/yi_sang.webp /images/sinners/ryoshu.webp)
    assert PlanIcons.icons(:battle_plans, Map.put(data, "lineups", []), nil) == []
  end

  test "gift icons are the first three distinct known gifts across milestones" do
    images = %{"A" => "/a.webp", "B" => "/b.webp", "C" => "/c.webp", "D" => "/d.webp"}
    entry = fn name -> %{"subject" => %{"gift" => name}} end
    data = %{"milestones" => [%{"entries" => [entry.("A"), %{"subject" => %{}}, entry.("Unknown"), entry.("A")]}, %{"entries" => [entry.("B"), entry.("C"), entry.("D")]}]}

    assert PlanIcons.icons(:gift_plans, data, images) == ["/a.webp", "/b.webp", "/c.webp"]
  end

  test "pack icons are hunted packs, hunt order first" do
    images = Map.new(~w(p1 p2 p3 p4 p5), &{&1, "/#{&1}.webp"})
    hunt = %{"normal" => %{"1" => "hunt"}}

    data = %{
      "packs" => %{"p1" => hunt, "p2" => hunt, "p3" => %{"normal" => %{"1" => "banned"}}, "p4" => hunt, "p5" => hunt},
      "order" => %{"normal" => %{"1" => ["p4", "p3", "p2"]}}
    }

    assert PlanIcons.icons(:pack_plans, data, images) == ["/p4.webp", "/p2.webp", "/p1.webp"]
    assert PlanIcons.icons(:pack_plans, %{}, images) == []
  end
end
