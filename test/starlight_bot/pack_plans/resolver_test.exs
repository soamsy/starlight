defmodule StarlightBot.PackPlans.ResolverTest do
  use ExUnit.Case, async: true

  alias StarlightBot.PackPlans.Resolver

  defp pack(id, normal_floors, hard_floors) do
    %{id: id, normal_floors: Jason.encode!(normal_floors), hard_floors: Jason.encode!(hard_floors)}
  end

  describe "mode_for_floor/2" do
    test "resolves the mode from the last breakpoint at or before the floor" do
      schedule = [%{"from_floor" => 1, "mode" => "normal"}, %{"from_floor" => 3, "mode" => "hard"}]

      assert Resolver.mode_for_floor(schedule, 1) == "normal"
      assert Resolver.mode_for_floor(schedule, 2) == "normal"
      assert Resolver.mode_for_floor(schedule, 3) == "hard"
      assert Resolver.mode_for_floor(schedule, 15) == "hard"
    end

    test "defaults to normal when there is no applicable breakpoint" do
      assert Resolver.mode_for_floor([], 1) == "normal"
      assert Resolver.mode_for_floor([%{"from_floor" => 5, "mode" => "hard"}], 1) == "normal"
    end

    test "extreme floors are always hard" do
      assert Resolver.mode_for_floor([], 6) == "hard"
      assert Resolver.mode_for_floor([], 15) == "hard"
    end
  end

  describe "eligible_floors/2" do
    test "reads the floor list for the requested mode" do
      p = pack("thm_1", [1], [1, 2])
      assert Resolver.eligible_floors(p, "normal") == [1]
      assert Resolver.eligible_floors(p, "hard") == [1, 2]
    end
  end

  describe "priority_for/3 and floors_for/4" do
    test "defaults to fine and all eligible floors when unspecified" do
      p = pack("thm_1", [1, 2], [1, 2, 3])
      assert Resolver.priority_for(%{}, "thm_1", "hard") == "fine"
      assert Resolver.floors_for(%{}, "thm_1", "hard", p) == [1, 2, 3]
    end

    test "reads an explicit priority and floor subset" do
      plan = %{"packs" => %{"thm_1" => %{"hard" => %{"priority" => "hunt", "floors" => [2, 3]}}}}
      p = pack("thm_1", [1, 2], [1, 2, 3])

      assert Resolver.priority_for(plan, "thm_1", "hard") == "hunt"
      assert Resolver.floors_for(plan, "thm_1", "hard", p) == [2, 3]
    end
  end

  describe "priority_at/4" do
    test "falls back to fine outside the assigned floor subset" do
      plan = %{"packs" => %{"thm_1" => %{"hard" => %{"priority" => "hunt", "floors" => [2, 3]}}}}
      p = pack("thm_1", [], [1, 2, 3])

      assert Resolver.priority_at(plan, p, "hard", 2) == "hunt"
      assert Resolver.priority_at(plan, p, "hard", 1) == "fine"
    end
  end

  describe "choose/6" do
    setup do
      banned = pack("thm_banned", [], [1, 2, 3])
      fine = pack("thm_fine", [], [1, 2, 3])
      hunt = pack("thm_hunt", [], [1, 2, 3])
      chance = pack("thm_chance", [], [1, 2, 3])

      plan = %{
        "packs" => %{
          "thm_banned" => %{"hard" => %{"priority" => "banned"}},
          "thm_hunt" => %{"hard" => %{"priority" => "hunt"}},
          "thm_chance" => %{"hard" => %{"priority" => "hunt", "chance" => true}}
        },
        "hunt_order" => %{"hard" => ["thm_chance", "thm_hunt"]}
      }

      all_packs = [banned, fine, hunt, chance]
      %{all_packs: all_packs, plan: plan}
    end

    test "the highest hunt pack in hunt order wins, chance or not", %{all_packs: all_packs, plan: plan} do
      [_banned, _fine, hunt, chance] = all_packs
      assert Resolver.choose([hunt, chance], all_packs, plan, "hard", 1, 3) == {:pick, "thm_chance"}

      reordered = put_in(plan, ["hunt_order", "hard"], ["thm_hunt", "thm_chance"])
      assert Resolver.choose([chance, hunt], all_packs, reordered, "hard", 1, 3) == {:pick, "thm_hunt"}
    end

    test "chance packs alone never hold out for a refresh", %{all_packs: all_packs, plan: plan} do
      [_banned, fine, _hunt, _chance] = all_packs
      chance_only = update_in(plan, ["packs"], &Map.delete(&1, "thm_hunt"))
      assert Resolver.choose([fine], all_packs, chance_only, "hard", 1, 3) == {:pick, "thm_fine"}
    end

    test "hunt is picked over fine", %{all_packs: all_packs, plan: plan} do
      [_banned, fine, hunt, _chance] = all_packs
      assert Resolver.choose([fine, hunt], all_packs, plan, "hard", 1, 3) == {:pick, "thm_hunt"}
    end

    test "fine is picked immediately when no hunt pack is in play" do
      fine = pack("thm_fine", [], [1, 2, 3])
      banned = pack("thm_banned2", [], [1, 2, 3])
      plan_without_hunt = %{"packs" => %{"thm_banned2" => %{"hard" => %{"priority" => "banned"}}}}

      assert Resolver.choose([fine, banned], [fine, banned], plan_without_hunt, "hard", 1, 3) ==
               {:pick, "thm_fine"}
    end

    test "fine holds out for a refresh when a hunt pack is still in play", %{all_packs: all_packs, plan: plan} do
      [banned, fine, _hunt, _chance] = all_packs
      assert Resolver.choose([fine, banned], all_packs, plan, "hard", 1, 3) == :refresh
    end

    test "refreshes when only banned packs are shown and refreshes remain", %{all_packs: all_packs, plan: plan} do
      [banned, _fine, _hunt, _chance] = all_packs
      assert Resolver.choose([banned], all_packs, plan, "hard", 1, 1) == :refresh
    end

    test "forced pick when only banned packs are shown and refreshes are gone", %{all_packs: all_packs, plan: plan} do
      [banned, _fine, _hunt, _chance] = all_packs
      assert Resolver.choose([banned], all_packs, plan, "hard", 1, 0) == {:forced_pick, "thm_banned"}
    end
  end
end
