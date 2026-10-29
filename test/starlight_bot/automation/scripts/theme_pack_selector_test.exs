defmodule StarlightBot.Automation.Scripts.ThemePackSelectorTest do
  use ExUnit.Case, async: true

  alias StarlightBot.Automation.Scripts.ThemePackSelector

  defp pack(id, normal_floors, hard_floors) do
    %{id: id, hook_name: "sleeve_#{id}", normal_floors: Jason.encode!(normal_floors), hard_floors: Jason.encode!(hard_floors)}
  end

  describe "packs_with_priority/5" do
    setup do
      %{
        packs: [
          pack("thm_hunt", [1, 2], [1, 2]),
          pack("thm_fine", [1, 2], [1, 2]),
          pack("thm_banned", [1, 2], [1, 2]),
          pack("thm_hard_only", [], [1, 2])
        ]
      }
    end

    test "filters by resolved priority at the given floor", %{packs: packs} do
      plan = %{
        "packs" => %{
          "thm_hunt" => %{"hard" => %{"priority" => "hunt"}},
          "thm_banned" => %{"hard" => %{"priority" => "banned"}}
        }
      }

      assert ThemePackSelector.packs_with_priority(plan, packs, "hard", 1, "hunt") |> Enum.map(& &1.id) == ["thm_hunt"]
      assert ThemePackSelector.packs_with_priority(plan, packs, "hard", 1, "banned") |> Enum.map(& &1.id) == ["thm_banned"]

      assert ThemePackSelector.packs_with_priority(plan, packs, "hard", 1, "fine") |> Enum.map(& &1.id) ==
               ["thm_fine", "thm_hard_only"]
    end

    test "excludes packs that don't appear in this mode at all", %{packs: packs} do
      assert ThemePackSelector.packs_with_priority(%{}, packs, "normal", 1, "fine") |> Enum.map(& &1.id) ==
               ["thm_hunt", "thm_fine", "thm_banned"]
    end

    test "respects per-floor scoping" do
      packs = [pack("thm_scoped", [1, 2, 3], [1, 2, 3])]
      plan = %{"packs" => %{"thm_scoped" => %{"normal" => %{"priority" => "hunt", "floors" => [2, 3]}}}}

      assert ThemePackSelector.packs_with_priority(plan, packs, "normal", 1, "hunt") == []
      assert ThemePackSelector.packs_with_priority(plan, packs, "normal", 2, "hunt") |> Enum.map(& &1.id) == ["thm_scoped"]
    end
  end

  describe "expected_pack_count/1" do
    test "base of 3 with no pack-count graces" do
      assert ThemePackSelector.expected_pack_count([]) == 3
      assert ThemePackSelector.expected_pack_count([%{"index" => 1}, %{"index" => 6, "enhance" => 2}]) == 3
    end

    test "each of graces 0, 2, 9 adds one, in either pick shape" do
      assert ThemePackSelector.expected_pack_count([%{"index" => 0}]) == 4
      assert ThemePackSelector.expected_pack_count([2, %{"index" => 9, "enhance" => 1}]) == 5
    end

    test "caps at 5" do
      assert ThemePackSelector.expected_pack_count([%{"index" => 0}, %{"index" => 2}, %{"index" => 9}]) == 5
    end
  end

  describe "refresh_budget/1" do
    test "one refresh without Interstellar Travel" do
      assert ThemePackSelector.refresh_budget([]) == 1
      assert ThemePackSelector.refresh_budget([%{"index" => 0}, %{"index" => 9, "enhance" => 2}]) == 1
    end

    test "Interstellar Travel adds 2, 3 or 4 by enhance level" do
      assert ThemePackSelector.refresh_budget([%{"index" => 2, "enhance" => 0}]) == 3
      assert ThemePackSelector.refresh_budget([2]) == 3
      assert ThemePackSelector.refresh_budget([%{"index" => 2, "enhance" => 1}]) == 4
      assert ThemePackSelector.refresh_budget([%{"index" => 0}, %{"index" => 2, "enhance" => 2}]) == 5
    end
  end

  describe "scroll_plan/1" do
    test "fast steps stop one row short of the bottom, then settled steps" do
      assert ThemePackSelector.scroll_plan(5) == {0, 3}
      assert ThemePackSelector.scroll_plan(10) == {0, 3}
      assert ThemePackSelector.scroll_plan(13) == {1, 3}
      assert ThemePackSelector.scroll_plan(21) == {3, 3}
    end

    test "unknown pane size settles every step" do
      assert ThemePackSelector.scroll_plan(nil) == {0, 16}
    end
  end

  describe "floor_pool/3" do
    test "keeps packs eligible on the floor for the mode" do
      packs = [pack("thm_a", [1, 2], [3]), pack("thm_b", [2], []), pack("thm_c", [], [1, 2])]

      assert ThemePackSelector.floor_pool(packs, "normal", 2) |> Enum.map(& &1.id) == ["thm_a", "thm_b"]
      assert ThemePackSelector.floor_pool(packs, "hard", 2) |> Enum.map(& &1.id) == ["thm_c"]
      assert ThemePackSelector.floor_pool(packs, "hard", 4) == []
    end
  end

  describe "search_target/6" do
    setup do
      packs = [pack("thm_a", [1, 2], [1, 2]), pack("thm_b", [1, 2], [1, 2]), pack("thm_c", [1, 2], [1, 2])]

      plan = %{
        "search_floors" => [2],
        "packs" => %{
          "thm_a" => %{"normal" => %{"priority" => "hunt"}},
          "thm_b" => %{"normal" => %{"priority" => "hunt"}}
        }
      }

      %{packs: packs, plan: plan}
    end

    test "picks the first hunt pack in list order", %{packs: packs, plan: plan} do
      assert %{id: "thm_a"} = ThemePackSelector.search_target(plan, packs, "normal", 2, [], fn _ -> true end)
    end

    test "nil when the floor isn't a search floor", %{packs: packs, plan: plan} do
      assert ThemePackSelector.search_target(plan, packs, "normal", 1, [], fn _ -> true end) == nil
      assert ThemePackSelector.search_target(Map.delete(plan, "search_floors"), packs, "normal", 2, [], fn _ -> true end) == nil
    end

    test "nil on F11+ even when listed as a search floor", %{packs: packs, plan: plan} do
      packs = Enum.map(packs, &%{&1 | hard_floors: Jason.encode!([11])})
      plan = %{plan | "search_floors" => [11], "packs" => %{"thm_a" => %{"hard" => %{"priority" => "hunt"}}}}
      assert ThemePackSelector.search_target(plan, packs, "hard", 11, [], fn _ -> true end) == nil
    end

    test "follows hunt order and prefers favorites", %{packs: packs, plan: plan} do
      assert %{id: "thm_b"} = ThemePackSelector.search_target(Map.put(plan, "hunt_order", %{"normal" => ["thm_b", "thm_a"]}), packs, "normal", 2, [], fn _ -> true end)

      favorite_a = plan |> put_in(["packs", "thm_a", "normal", "favorite"], true) |> Map.put("hunt_order", %{"normal" => ["thm_b", "thm_a"]})
      assert %{id: "thm_a"} = ThemePackSelector.search_target(favorite_a, packs, "normal", 2, [], fn _ -> true end)
      assert ThemePackSelector.search_target(favorite_a, packs, "normal", 2, ["thm_a"], fn _ -> true end) == nil
    end

    test "skips visited packs and packs without a usable search hook", %{packs: packs, plan: plan} do
      assert %{id: "thm_b"} = ThemePackSelector.search_target(plan, packs, "normal", 2, ["thm_a"], fn _ -> true end)
      assert %{id: "thm_b"} = ThemePackSelector.search_target(plan, packs, "normal", 2, [], &(&1.id != "thm_a"))
      assert ThemePackSelector.search_target(plan, packs, "normal", 2, ["thm_a", "thm_b"], fn _ -> true end) == nil
    end
  end

  describe "pick_winner/5" do
    test "returns :none for no matches" do
      assert ThemePackSelector.pick_winner([], %{}, %{}, "hard", 1) == :none
    end

    test "hunt packs win in hunt order" do
      plan = %{
        "packs" => %{
          "thm_favorite" => %{"hard" => %{"priority" => "hunt", "favorite" => true}},
          "thm_hunt" => %{"hard" => %{"priority" => "hunt"}}
        },
        "hunt_order" => %{"hard" => ["thm_favorite", "thm_hunt"]}
      }

      pack_a = pack("thm_hunt", [1], [1])
      pack_b = pack("thm_favorite", [1], [1])
      matched_pairs = [{pack_a, :hook_hunt}, {pack_b, :hook_favorite}]
      matched_hooks = %{hook_hunt: {1, 1, 10, 10}, hook_favorite: {2, 2, 10, 10}}

      assert ThemePackSelector.pick_winner(matched_pairs, matched_hooks, plan, "hard", 1) == {:ok, pack_b, {2, 2, 10, 10}}

      reordered = put_in(plan, ["hunt_order", "hard"], ["thm_hunt", "thm_favorite"])
      assert ThemePackSelector.pick_winner(matched_pairs, matched_hooks, reordered, "hard", 1) == {:ok, pack_a, {1, 1, 10, 10}}
    end

    test "The B.E. beats everything in an extreme run, and only then" do
      plan = %{
        "mode_schedule" => [%{"from_floor" => 1, "mode" => "hard"}],
        "extreme" => true,
        "packs" => %{"thm_hunt" => %{"hard" => %{"priority" => "hunt"}}, "thm_116" => %{"hard" => %{"priority" => "banned"}}}
      }

      pack_hunt = pack("thm_hunt", [1], [1])
      pack_be = pack("thm_116", [1], [1])
      matched_pairs = [{pack_hunt, :hook_hunt}, {pack_be, :hook_be}]
      matched_hooks = %{hook_hunt: {1, 1, 10, 10}, hook_be: {2, 2, 10, 10}}

      assert ThemePackSelector.pick_winner(matched_pairs, matched_hooks, plan, "hard", 1) == {:ok, pack_be, {2, 2, 10, 10}}

      not_extreme = Map.put(plan, "extreme", false)
      assert ThemePackSelector.pick_winner(matched_pairs, matched_hooks, not_extreme, "hard", 1) == {:ok, pack_hunt, {1, 1, 10, 10}}
    end

    test "falls back through the tiers when a higher one has no match" do
      plan = %{"packs" => %{"thm_hunt" => %{"hard" => %{"priority" => "hunt"}}}}
      pack_fine = pack("thm_fine", [1], [1])
      pack_hunt = pack("thm_hunt", [1], [1])

      matched_pairs = [{pack_fine, :hook_fine}, {pack_hunt, :hook_hunt}]
      matched_hooks = %{hook_fine: {0, 0, 5, 5}, hook_hunt: {9, 9, 5, 5}}

      assert ThemePackSelector.pick_winner(matched_pairs, matched_hooks, plan, "hard", 1) == {:ok, pack_hunt, {9, 9, 5, 5}}
    end

    test "ties within a tier keep the first match" do
      plan = %{"packs" => %{}}
      pack_a = pack("thm_a", [1], [1])
      pack_b = pack("thm_b", [1], [1])

      matched_pairs = [{pack_a, :hook_a}, {pack_b, :hook_b}]
      matched_hooks = %{hook_a: {0, 0, 1, 1}, hook_b: {1, 1, 1, 1}}

      assert ThemePackSelector.pick_winner(matched_pairs, matched_hooks, plan, "hard", 1) == {:ok, pack_a, {0, 0, 1, 1}}
    end
  end
end
