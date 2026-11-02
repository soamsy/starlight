defmodule StarlightBot.PackPlans.ResolverTest do
  use ExUnit.Case, async: true

  alias StarlightBot.PackPlans.Resolver

  defp pack(id, normal_floors, hard_floors) do
    %{id: id, normal_floors: Jason.encode!(normal_floors), hard_floors: Jason.encode!(hard_floors)}
  end

  describe "mode override" do
    @plan %{"mode_schedule" => [%{"from_floor" => 4, "mode" => "hard"}], "extreme" => false, "packs" => %{}}

    test "default and unknown values leave the plan's schedule alone" do
      assert Resolver.with_mode_override(@plan, "default") == @plan
      assert Resolver.with_mode_override(@plan, nil) == @plan
      assert Resolver.parse_mode_override("bogus") == "default"
    end

    test "hard_N switches to hard at floor N and drops extreme" do
      plan = Resolver.with_mode_override(Map.put(@plan, "extreme", true), "hard_2")
      assert Enum.map(1..3, &Resolver.mode_for_floor(plan["mode_schedule"], &1)) == ["normal", "hard", "hard"]
      refute Resolver.extreme?(plan)
    end

    test "extreme is hard from floor 1 with extreme on" do
      plan = Resolver.with_mode_override(@plan, "extreme")
      assert Resolver.mode_for_floor(plan["mode_schedule"], 1) == "hard"
      assert Resolver.extreme?(plan)
    end
  end

  describe "search override" do
    @searching %{"search_floors" => [2, 4]}

    test "default and unknown values keep the plan's search floors" do
      assert Resolver.with_search_override(@searching, "default") == @searching
      assert Resolver.parse_search_override("bogus") == "default"
    end

    test "all searches every searchable floor and none searches nothing" do
      assert Resolver.with_search_override(@searching, "all")["search_floors"] == Enum.to_list(1..10)
      assert Resolver.with_search_override(@searching, "none")["search_floors"] == []
    end
  end

  describe "extreme mode" do
    @all_hard [%{"from_floor" => 1, "mode" => "hard"}]

    test "is only allowed when F1 starts hard" do
      assert Resolver.extreme_allowed?(%{"mode_schedule" => @all_hard})
      refute Resolver.extreme_allowed?(%{"mode_schedule" => []})
      refute Resolver.extreme_allowed?(%{"mode_schedule" => [%{"from_floor" => 2, "mode" => "hard"}]})
      refute Resolver.extreme_allowed?(%{})
    end

    test "requires both the toggle and an all-hard schedule" do
      assert Resolver.extreme?(%{"extreme" => true, "mode_schedule" => @all_hard})
      refute Resolver.extreme?(%{"mode_schedule" => @all_hard})
      refute Resolver.extreme?(%{"extreme" => true, "mode_schedule" => []})
    end

    test "pack search stops at F10" do
      assert Resolver.searchable_floor?(10)
      refute Resolver.searchable_floor?(11)
    end
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

  describe "status_at/4 and priority_at/4" do
    test "defaults to none and fine when unspecified" do
      p = pack("thm_1", [1, 2], [1, 2, 3])
      assert Resolver.status_at(%{}, "thm_1", "hard", 1) == "none"
      assert Resolver.priority_at(%{}, p, "hard", 1) == "fine"
    end

    test "statuses are kept per floor and per mode" do
      plan = %{"packs" => %{"thm_1" => %{"hard" => %{"1" => "favorite", "2" => "hunt", "3" => "banned"}}}}
      p = pack("thm_1", [], [1, 2, 3, 4])

      assert Enum.map(1..4, &Resolver.status_at(plan, "thm_1", "hard", &1)) == ["favorite", "hunt", "banned", "none"]
      assert Resolver.status_at(plan, "thm_1", "normal", 1) == "none"
      assert Enum.map(1..4, &Resolver.priority_at(plan, p, "hard", &1)) == ["hunt", "hunt", "banned", "fine"]
      assert Resolver.favorite?(plan, "thm_1", "hard", 1)
      refute Resolver.favorite?(plan, "thm_1", "hard", 2)
      assert Enum.sort(Resolver.hunted_floors(plan, "thm_1", "hard")) == [1, 2]
    end
  end

  describe "sort_hunt/4" do
    test "favorites first, then the floor's own order" do
      plan = %{
        "packs" => %{
          "a" => %{"hard" => %{"1" => "hunt", "2" => "hunt"}},
          "b" => %{"hard" => %{"1" => "favorite", "2" => "hunt"}},
          "c" => %{"hard" => %{"1" => "hunt", "2" => "hunt"}}
        },
        "order" => %{"hard" => %{"1" => ["a", "b", "c"], "2" => ["c", "a", "b"]}}
      }

      packs = [%{id: "a"}, %{id: "b"}, %{id: "c"}]
      assert Enum.map(Resolver.sort_hunt(packs, plan, "hard", 1), & &1.id) == ["b", "a", "c"]
      assert Enum.map(Resolver.sort_hunt(packs, plan, "hard", 2), & &1.id) == ["c", "a", "b"]
    end
  end

  describe "choose/6" do
    setup do
      banned = pack("thm_banned", [], [1, 2, 3])
      fine = pack("thm_fine", [], [1, 2, 3])
      hunt = pack("thm_hunt", [], [1, 2, 3])
      favorite = pack("thm_favorite", [], [1, 2, 3])

      plan = %{
        "packs" => %{
          "thm_banned" => %{"hard" => %{"1" => "banned"}},
          "thm_hunt" => %{"hard" => %{"1" => "hunt"}},
          "thm_favorite" => %{"hard" => %{"1" => "favorite"}}
        },
        "order" => %{"hard" => %{"1" => ["thm_favorite", "thm_hunt"]}}
      }

      all_packs = [banned, fine, hunt, favorite]
      %{all_packs: all_packs, plan: plan}
    end

    test "a favorite beats a hunt pack regardless of order", %{all_packs: all_packs, plan: plan} do
      [_banned, _fine, hunt, favorite] = all_packs
      assert Resolver.choose([hunt, favorite], all_packs, plan, "hard", 1, 3) == {:pick, "thm_favorite"}

      reordered = put_in(plan, ["order", "hard", "1"], ["thm_hunt", "thm_favorite"])
      assert Resolver.choose([favorite, hunt], all_packs, reordered, "hard", 1, 3) == {:pick, "thm_favorite"}
    end

    test "hunt packs follow the floor's order", %{all_packs: all_packs, plan: plan} do
      [_banned, _fine, hunt, _favorite] = all_packs
      other = pack("thm_other", [], [1, 2, 3])
      plan = plan |> put_in(["packs", "thm_other"], %{"hard" => %{"1" => "hunt"}}) |> put_in(["order", "hard", "1"], ["thm_other", "thm_hunt"])
      assert Resolver.choose([hunt, other], [hunt, other | all_packs], plan, "hard", 1, 3) == {:pick, "thm_other"}
    end

    test "statuses on other floors do not apply", %{all_packs: all_packs, plan: plan} do
      [_banned, _fine, hunt, _favorite] = all_packs
      assert Resolver.priority_at(plan, hunt, "hard", 2) == "fine"
    end

    test "a lone favorite still holds out for a refresh", %{all_packs: all_packs, plan: plan} do
      [_banned, fine, _hunt, _favorite] = all_packs
      favorite_only = update_in(plan, ["packs"], &Map.delete(&1, "thm_hunt"))
      assert Resolver.choose([fine], all_packs, favorite_only, "hard", 1, 3) == :refresh
    end

    test "hunt is picked over fine", %{all_packs: all_packs, plan: plan} do
      [_banned, fine, hunt, _favorite] = all_packs
      assert Resolver.choose([fine, hunt], all_packs, plan, "hard", 1, 3) == {:pick, "thm_hunt"}
    end

    test "fine is picked immediately when no hunt pack is in play" do
      fine = pack("thm_fine", [], [1, 2, 3])
      banned = pack("thm_banned2", [], [1, 2, 3])
      plan_without_hunt = %{"packs" => %{"thm_banned2" => %{"hard" => %{"1" => "banned"}}}}

      assert Resolver.choose([fine, banned], [fine, banned], plan_without_hunt, "hard", 1, 3) ==
               {:pick, "thm_fine"}
    end

    test "fine holds out for a refresh when a hunt pack is still in play", %{all_packs: all_packs, plan: plan} do
      [banned, fine, _hunt, _favorite] = all_packs
      assert Resolver.choose([fine, banned], all_packs, plan, "hard", 1, 3) == :refresh
    end

    test "refreshes when only banned packs are shown and refreshes remain", %{all_packs: all_packs, plan: plan} do
      [banned, _fine, _hunt, _favorite] = all_packs
      assert Resolver.choose([banned], all_packs, plan, "hard", 1, 1) == :refresh
    end

    test "forced pick when only banned packs are shown and refreshes are gone", %{all_packs: all_packs, plan: plan} do
      [banned, _fine, _hunt, _favorite] = all_packs
      assert Resolver.choose([banned], all_packs, plan, "hard", 1, 0) == {:forced_pick, "thm_banned"}
    end
  end
end
